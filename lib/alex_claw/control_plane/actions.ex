defmodule AlexClaw.ControlPlane.Actions do
  @moduledoc """
  What each catalogued action does, once `AlexClaw.ControlPlane.perform/3`
  has allowed it. Nothing else calls these; the entry points name an action
  and its params, and the control plane decides.

  A **change** (`kind/1`) runs inside the transaction that holds its audit
  row, so it touches the database and nothing else; what lies outside the
  database — caches, broadcasts, schedules, other nodes, discovery — runs in
  `after_commit/4`. An **effect** (a run, a download, a staged upload) starts
  once its audit row is written.

  `describe/2` is the detail of the audit row. It never holds a secret's
  value: a login is named by its field, a setting by `params[:detail]` as the
  page describes it.
  """

  alias AlexClaw.Auth.{Policies, PolicyEngine, RecoveryCodes, SecondFactor, Sessions, TOTP}
  alias AlexClaw.{Cluster, Config, ControlPlane, LLM, Memory, Repo, Resources, Workflows}
  alias AlexClaw.ControlPlane.Context
  alias AlexClaw.Database.{DataExport, Dump}
  alias AlexClaw.MCP.Key
  alias AlexClaw.WebAutomation.Recording
  alias AlexClaw.Workflows.{Launch, SchedulerSync, SkillRegistry, WorkflowStep}

  @pending_secret "auth.totp.pending_secret"

  @effects [:run_workflow, :download_database, :export_data, :export_workflow, :stage_skill]

  # Catalogued, but still reached by their old paths (AuthCommands, the
  # gateway, MCP, SkillAPI): perform/3 refuses them with :not_wired until
  # S5b moves them here.
  @not_wired [
    :load_skill,
    :unload_skill,
    :generate_skill,
    :set_gateway_owner,
    :connect_google,
    :disconnect_google,
    :upgrade_secrets,
    :restore_data,
    :run_protected_workflow,
    :run_skill,
    :run_privileged_skill,
    :record,
    :replay
  ]

  @doc "Whether `action` runs here yet; one that does not is refused, never attempted."
  @spec wired?(atom()) :: boolean()
  def wired?(action), do: action not in @not_wired

  @doc "Whether `action` is a `:change` (transactional) or an `:effect`."
  @spec kind(atom()) :: :change | :effect
  def kind(action) when action in @effects, do: :effect
  def kind(_action), do: :change

  @doc "Run `action` with `params`: `{:ok, result}` or `{:error, reason}`."
  @spec run(atom(), map()) :: {:ok, term()} | {:error, term()}

  # --- workflows

  def run(:save_workflow, %{attrs: attrs} = params),
    do: save_workflow(params[:workflow], attrs)

  def run(:delete_workflow, %{workflow_id: id}) do
    with {:ok, workflow} <- Workflows.get_workflow(id), do: Workflows.delete_workflow(workflow)
  end

  def run(:duplicate_workflow, %{workflow_id: id}) do
    with {:ok, workflow} <- Workflows.get_workflow(id), do: Workflows.duplicate_workflow(workflow)
  end

  def run(:import_workflow, %{data: data}), do: imported(Workflows.import_workflow(data))

  def run(:save_step, %{step_id: id, attrs: attrs}) do
    with {:ok, step} <- fetch_step(id), do: Workflows.update_step(step, attrs)
  end

  def run(:save_step, %{workflow: workflow, attrs: attrs}),
    do: Workflows.add_step(workflow, attrs)

  def run(:remove_step, %{step_id: id}) do
    with {:ok, step} <- fetch_step(id), do: Workflows.remove_step(step)
  end

  def run(:reorder_steps, %{workflow: workflow, step_ids: step_ids}),
    do: Workflows.reorder_steps(workflow, step_ids)

  def run(:assign_resource, %{workflow: workflow, resource_id: id, assigned: true}),
    do: Workflows.assign_resource(workflow, id)

  def run(:assign_resource, %{workflow: workflow, resource_id: id, assigned: false}),
    do: {:ok, Workflows.unassign_resource(workflow, id)}

  # --- resources: discovery fetches the API and writes back, so it starts
  # after commit (`after_commit/4`), never inside the change.

  def run(:save_resource, %{attrs: attrs} = params),
    do: save_resource(params[:resource], attrs)

  def run(:delete_resource, %{resource_id: id}) do
    with {:ok, resource} <- Resources.get_resource(id), do: Resources.delete_resource(resource)
  end

  def run(:discover_resource, %{resource_id: id}), do: Resources.get_resource(id)

  # The login goes into the slot and the recording is saved through
  # Resources, which stores it in OpenBao, bound to the recording's origin.
  def run(:attach_login, %{resource_id: id, selector: selector, value: value}) do
    with {:ok, resource} <- Resources.get_resource(id),
         {:ok, metadata} <- Recording.filled(resource.metadata || %{}, selector, value) do
      Resources.update_resource(resource, %{metadata: metadata}, skip_discovery: true)
    end
  end

  # --- settings and secrets

  def run(action, %{key: key, delete: true}) when action in [:set_setting, :set_secret],
    do: Config.remove(key)

  def run(action, %{key: key, value: value, opts: opts})
      when action in [:set_setting, :set_secret] do
    with {:ok, _setting} <- Config.persist(key, value, opts),
         {:ok, assigned} <- assign_gateway_node(key, value),
         do: {:ok, [key | assigned]}
  end

  def run(:clear_secret, %{key: key}) do
    with :ok <- Config.clear(key), do: {:ok, key}
  end

  def run(:generate_mcp_key, _params), do: Key.generate()

  # --- providers, policies, nodes

  def run(:save_provider, %{provider_id: id, delete: true}) do
    with {:ok, provider} <- LLM.get_provider(id), do: LLM.delete_provider(provider)
  end

  def run(:save_provider, %{attrs: attrs} = params), do: save_provider(params[:provider], attrs)

  def run(:save_policy, %{policy_id: id, delete: true}), do: Policies.delete_policy(id)
  def run(:save_policy, %{policy_id: id, toggle: true}), do: Policies.toggle_policy(id)
  def run(:save_policy, %{policy_id: id, attrs: attrs}), do: Policies.update_policy(id, attrs)
  def run(:save_policy, %{attrs: attrs}), do: Policies.create_policy(attrs)

  def run(:save_node, %{node_id: id, delete: true}),
    do: Cluster.delete_node(Cluster.get_node!(id))

  def run(:save_node, %{node_id: id, connect: true}), do: {:ok, Cluster.get_node!(id)}
  def run(:save_node, %{attrs: attrs}), do: Cluster.create_node(attrs)

  def run(:delete_memory, %{entry_id: id}), do: Memory.delete_entry(id)

  # --- identity. TOTP refuses a setup while 2FA is on. Confirming it hands
  # out the first recovery codes.

  def run(:set_up_second_factor, %{step: :setup}), do: TOTP.setup()

  def run(:set_up_second_factor, %{step: :confirm, code: code}) do
    with :ok <- TOTP.confirm_setup(code), do: {:ok, RecoveryCodes.generate()}
  end

  def run(:set_up_second_factor, %{step: :cancel}), do: Config.remove(@pending_secret)

  # Disabling the second factor happens as its code is checked, in the same
  # transaction as this row (`verifier/2`: `TOTP.disable_by/1` verifies and
  # disables in one step, so no caller can turn it off by forgetting the
  # check).
  def run(:disable_second_factor, _params), do: {:ok, :disabled}
  def run(:regenerate_recovery_codes, _params), do: {:ok, RecoveryCodes.generate()}
  def run(:sign_out_everywhere, _params), do: Sessions.remove_all()

  # --- data and runs

  def run(:clear_run_history, %{workflow_id: id}), do: {:ok, Workflows.clear_runs(id)}

  def run(:run_workflow, %{workflow_id: id}) do
    with {:ok, workflow} <- Workflows.get_workflow(id),
         do: launched(Launch.start(workflow), workflow)
  end

  def run(:download_database, %{acc: acc, open: open, emit: emit}),
    do: {:ok, Dump.write(open.(acc), emit)}

  def run(:export_data, %{acc: acc, open: open, emit: emit}),
    do: {:ok, DataExport.write(open.(acc), emit)}

  def run(:export_workflow, %{workflow_id: id}) do
    with {:ok, workflow} <- Workflows.get_workflow(id),
         do: {:ok, {workflow, Workflows.export_workflow(workflow)}}
  end

  # Staged under skills_dir/pending, never the live directory: loading it
  # is :load_skill, which approves that file's code.
  def run(:stage_skill, %{path: path, name: name}), do: SkillRegistry.stage_upload(path, name)

  @doc """
  What to run once a change is committed: everything that is not the
  database. Safe to repeat.
  """
  @spec after_commit(atom(), map(), term(), Context.t()) :: term()
  def after_commit(action, _params, _result, _context)
      when action in [:save_workflow, :delete_workflow],
      do: SchedulerSync.sync()

  def after_commit(action, params, resource, context)
      when action in [:save_resource, :discover_resource] do
    discover(params, resource, Context.requester(context))
  end

  def after_commit(action, _params, keys, _context)
      when action in [:set_setting, :set_secret] and is_list(keys),
      do: Enum.each(keys, &Config.publish/1)

  def after_commit(action, %{key: key, delete: true}, _removed, _context)
      when action in [:set_setting, :set_secret],
      do: Config.publish(key)

  def after_commit(:save_policy, _params, _policy, _context), do: PolicyEngine.reload_policies()

  def after_commit(:set_up_second_factor, %{step: :cancel}, _removed, _context),
    do: Config.publish(@pending_secret)

  # Asking a node whether it answers is not something a transaction can hold:
  # the answer, and the status it sets, are recorded once known.
  def after_commit(:save_node, %{connect: true}, node, context) do
    status = if Cluster.node_ping(node.name) == :pong, do: "connected", else: "disconnected"

    ControlPlane.outcome_for(
      Context.requester(context),
      "cluster node connect: id #{node.id} — #{status}",
      fn -> Cluster.update_node(node, %{status: status, last_seen_at: DateTime.utc_now()}) end
    )
  end

  def after_commit(:sign_out_everywhere, _params, socket_ids, _context),
    do: Sessions.disconnect(socket_ids)

  def after_commit(_action, _params, _result, _context), do: :ok

  @doc """
  The check for a per-action code: a function that verifies `code` (and, for
  `:disable_second_factor`, disables the second factor as it does).
  """
  @spec verifier(atom(), String.t()) :: (-> {:ok, atom()} | {:error, :invalid_code})
  def verifier(:disable_second_factor, code), do: fn -> TOTP.disable_by(code) end

  def verifier(_action, code),
    do: fn -> SecondFactor.impl().verify(code, :web) end

  @doc "The detail of the audit row for `action`: never a secret's value."
  @spec describe(atom(), map()) :: String.t()
  def describe(_action, %{detail: detail}), do: detail
  def describe(:save_workflow, %{attrs: attrs}), do: "workflow #{attrs[:name]}"

  def describe(:run_workflow, %{workflow_id: id}), do: "workflow #{workflow_name(id)} (id #{id})"

  def describe(:attach_login, %{resource_id: id, selector: selector}),
    do: "recording id #{id}, login for #{selector}"

  def describe(:stage_skill, %{name: name}), do: "skill upload #{name}"
  def describe(:set_up_second_factor, %{step: step}), do: "second factor set-up: #{step}"

  def describe(_action, params) do
    params
    |> Map.take([
      :workflow_id,
      :step_id,
      :resource_id,
      :provider_id,
      :policy_id,
      :node_id,
      :entry_id,
      :key
    ])
    |> Enum.map_join(", ", fn {field, value} -> "#{field} #{value}" end)
  end

  defp workflow_name(id) do
    case Workflows.get_workflow(id) do
      {:ok, workflow} -> workflow.name
      {:error, :not_found} -> "not found"
    end
  end

  defp save_workflow(nil, attrs), do: Workflows.create_workflow(attrs)
  defp save_workflow(workflow, attrs), do: Workflows.update_workflow(workflow, attrs)

  defp imported({:ok, workflow, warnings}), do: {:ok, {workflow, warnings}}
  defp imported({:error, message}), do: {:error, {:import_failed, message}}

  defp fetch_step(id) do
    case Repo.get(WorkflowStep, id) do
      nil -> {:error, :step_not_found}
      step -> {:ok, step}
    end
  end

  defp save_resource(nil, attrs), do: Resources.create_resource(attrs, skip_discovery: true)

  defp save_resource(resource, attrs),
    do: Resources.update_resource(resource, attrs, skip_discovery: true)

  defp discover(%{discover: false}, _resource, _requester), do: :ok
  defp discover(_params, resource, requester), do: Resources.discover(resource, requester)

  defp save_provider(nil, attrs), do: LLM.create_provider(attrs)
  defp save_provider(provider, attrs), do: LLM.update_provider(provider, attrs)

  # Enabling a gateway assigns it to this node — telegram.enabled sets
  # telegram.node — in the same transaction as the setting itself. Answers the
  # further keys it wrote, for publishing after commit.
  defp assign_gateway_node(key, value) when value in ["true", true],
    do: assign_node(String.ends_with?(key, ".enabled"), key)

  defp assign_gateway_node(_key, _value), do: {:ok, []}

  defp assign_node(true, key) do
    node_key = String.replace(key, ".enabled", ".node")
    category = key |> String.split(".") |> hd()

    with {:ok, _setting} <- Config.persist(node_key, to_string(node()), category: category),
         do: {:ok, [node_key]}
  end

  defp assign_node(false, _key), do: {:ok, []}

  defp launched({:error, _reason} = refused, _workflow), do: refused
  defp launched(result, workflow), do: {:ok, {result, workflow}}
end
