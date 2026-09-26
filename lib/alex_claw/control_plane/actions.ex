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

  alias AlexClaw.Auth.{
    Elevation,
    Policies,
    PolicyEngine,
    RecoveryCodes,
    SecondFactor,
    Sessions,
    TOTP
  }

  alias AlexClaw.{Cluster, Config, ControlPlane, LLM, Memory, Repo, Resources, Workflows}
  alias AlexClaw.ControlPlane.{Context, Effects}
  alias AlexClaw.Database.DataSet
  alias AlexClaw.MCP.Key
  alias AlexClaw.WebAutomation.Recording
  alias AlexClaw.Workflows.{SchedulerSync, Workflow, WorkflowStep}

  @gateway_owners ~w(telegram.chat_id discord.channel_id)

  # The changes: one database write each, in the transaction with its row.
  @changes [
    :save_workflow,
    :delete_workflow,
    :duplicate_workflow,
    :import_workflow,
    :save_step,
    :remove_step,
    :reorder_steps,
    :assign_resource,
    :save_resource,
    :delete_resource,
    :discover_resource,
    :attach_login,
    :set_setting,
    :set_secret,
    :clear_secret,
    :generate_mcp_key,
    :set_gateway_owner,
    :save_provider,
    :save_policy,
    :save_node,
    :delete_memory,
    :set_up_second_factor,
    :disable_second_factor,
    :regenerate_recovery_codes,
    :sign_out_everywhere,
    :clear_run_history
  ]

  @doc "Whether `action` has an implementation here: every catalogued action does."
  @spec wired?(atom()) :: boolean()
  def wired?(action), do: action in @changes or action in Effects.actions()

  @doc """
  Whether this request may be performed at all, beyond the catalogue: checked
  before anything is written or started, so a refusal leaves no run behind.
  Another node (`:cluster`) may run a workflow only when it is registered,
  the workflow's first step is the `receive_from_workflow` gate, that gate's
  `allowed_nodes` names it (empty allows no one), and the workflow is not
  protected.
  """
  @spec admissible(atom(), map(), Context.t()) :: :ok | {:error, atom()}
  def admissible(:run_workflow, %{workflow_id: id}, %Context{entry_point: :cluster, node: node}) do
    with :ok <- registered(Cluster.get_by_name(node)),
         {:ok, workflow} <- Workflows.get_workflow(id),
         :ok <- gate_allows(first_step(workflow.steps), node),
         do: unprotected(Workflow.protected?(workflow))
  end

  # The admin's identity (the password's hash, auth.totp.*) is written only by
  # its own flows — login, second-factor setup — never as a setting, from any
  # entry point (S8 M15).
  def admissible(action, %{key: key}, _context)
      when action in [:set_setting, :set_secret, :set_gateway_owner],
      do: not_identity(DataSet.identity_setting?(key))

  def admissible(_action, _params, _context), do: :ok

  defp not_identity(false), do: :ok
  defp not_identity(true), do: {:error, :identity_setting}

  defp registered(nil), do: {:error, :node_not_registered}
  defp registered(_node), do: :ok

  defp first_step([]), do: nil
  defp first_step(steps), do: Enum.min_by(steps, & &1.position)

  defp gate_allows(%{skill: "receive_from_workflow", config: config}, node),
    do: listed((config || %{})["allowed_nodes"], node)

  defp gate_allows(_first_step, _node), do: {:error, :no_receive_gate}

  # An empty or absent allowed_nodes allows no one: a workflow names who may
  # trigger it.
  defp listed(allowed, node) when is_list(allowed), do: allowed_node(node in allowed)
  defp listed(_absent, _node), do: {:error, :node_not_allowed}

  defp allowed_node(true), do: :ok
  defp allowed_node(false), do: {:error, :node_not_allowed}

  defp unprotected(true), do: {:error, :protected_workflow}
  defp unprotected(false), do: :ok

  @doc "Whether `action` is a `:change` (transactional) or an `:effect` (`AlexClaw.ControlPlane.Effects`)."
  @spec kind(atom()) :: :change | :effect
  def kind(action), do: if(action in @changes, do: :change, else: :effect)

  @doc "Run `action` with `params`: `{:ok, result}` or `{:error, reason}`."
  @spec run(atom(), map()) :: {:ok, term()} | {:error, term()} | term()

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

  def run(action, %{key: key, delete: true})
      when action in [:set_setting, :set_secret, :set_gateway_owner],
      do: Config.remove(key)

  def run(action, %{key: key, value: value, opts: opts})
      when action in [:set_setting, :set_secret] do
    with {:ok, _setting} <- Config.persist(key, value, opts),
         {:ok, assigned} <- assign_gateway_node(key, value),
         do: {:ok, [key | assigned]}
  end

  def run(:clear_secret, %{key: key}) do
    with :ok <- Config.erase(key), do: {:ok, key}
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

  def run(:set_up_second_factor, %{step: :cancel}), do: TOTP.cancel_setup()

  # Disabling the second factor happens as its code is checked, in the same
  # transaction as this row (`verifier/2`: `TOTP.disable_by/1` verifies and
  # disables in one step, so no caller can turn it off by forgetting the
  # check).
  def run(:disable_second_factor, _params), do: {:ok, :disabled}
  def run(:regenerate_recovery_codes, _params), do: {:ok, RecoveryCodes.generate()}
  def run(:sign_out_everywhere, _params), do: Sessions.remove_all()

  # --- data and runs

  def run(:clear_run_history, %{workflow_id: id}), do: {:ok, Workflows.clear_runs(id)}

  def run(:set_gateway_owner, %{key: key, value: value}) when key in @gateway_owners do
    with {:ok, _setting} <- Config.persist(key, value, type: "string", category: category(key)),
         do: {:ok, [key]}
  end

  def run(action, params), do: Effects.run(action, params)

  defp category(key), do: key |> String.split(".") |> hd()

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
      when action in [:set_setting, :set_secret, :set_gateway_owner] and is_list(keys),
      do: Enum.each(keys, &Config.publish/1)

  def after_commit(action, %{key: key, delete: true}, _removed, _context)
      when action in [:set_setting, :set_secret, :set_gateway_owner],
      do: Config.publish(key)

  def after_commit(:save_policy, _params, _policy, _context), do: PolicyEngine.reload_policies()

  # Cleared or generated inside the transaction; announced once committed.
  def after_commit(:clear_secret, %{key: key}, _key, _context), do: Config.publish(key)
  def after_commit(:generate_mcp_key, _params, _key, _context), do: Config.publish("mcp.api_key")

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

  # Every login is closed, so every elevation ends with it.
  def after_commit(:sign_out_everywhere, _params, socket_ids, _context) do
    Elevation.revoke_all()
    Sessions.disconnect(socket_ids)
  end

  # Disabled in the database as the code was checked; the cache and OpenBao
  # follow only once that is committed (S8 M17).
  def after_commit(:disable_second_factor, _params, _result, _context), do: TOTP.disabled()

  def after_commit(_action, _params, _result, _context), do: :ok

  @doc """
  The check for a per-action code: a function that verifies `code` (and, for
  `:disable_second_factor`, disables the second factor as it does).
  """
  @spec verifier(atom(), String.t()) :: (-> {:ok, atom()} | {:error, :invalid_code})
  def verifier(:disable_second_factor, code), do: fn -> TOTP.disable_by(code) end

  def verifier(_action, code),
    do: fn -> SecondFactor.impl().verify(code, :web) end

  @doc """
  Whether a gateway challenge answered with a code was raised for this
  `action` with these `params`: a chat's code approves the run it was sent
  for, nothing else.
  """
  @spec challenged?(atom(), map()) :: (map() -> boolean())
  def challenged?(:run_protected_workflow, %{workflow_id: id}),
    do: &match?(%{type: :run_workflow, workflow_id: ^id}, &1)

  def challenged?(_action, _params), do: fn _challenged -> false end

  @doc "The detail of the audit row for `action`: never a secret's value."
  @spec describe(atom(), map()) :: String.t()
  def describe(_action, %{detail: detail}), do: detail
  def describe(:save_workflow, %{attrs: attrs}), do: "workflow #{attrs[:name]}"

  def describe(action, %{workflow_id: id})
      when action in [:run_workflow, :run_protected_workflow],
      do: "workflow #{workflow_name(id)} (id #{id})"

  def describe(:attach_login, %{resource_id: id, selector: selector}),
    do: "recording id #{id}, login for #{selector}"

  def describe(:stage_skill, %{name: name}), do: "skill upload #{name}"

  def describe(action, %{skill: skill}) when action in [:run_skill, :run_privileged_skill],
    do: "skill #{skill}"

  def describe(:generate_skill, %{skill_name: name}), do: "skill #{name}"
  def describe(:load_skill, %{file_path: path}), do: "skill file #{path}"

  def describe(action, %{name: name}) when action in [:load_skill, :unload_skill],
    do: "skill #{name}"

  def describe(:restore_data, %{filename: filename}), do: "restore from #{filename}"
  def describe(:record, %{url: url}), do: "recording of #{url}"
  def describe(:record, %{stop: session_id}), do: "recording #{session_id} stopped"
  def describe(:connect_google, %{step: step}), do: "Google connection: #{step}"
  def describe(:set_gateway_owner, %{key: key}), do: "#{key} set"
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
end
