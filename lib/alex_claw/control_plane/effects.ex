defmodule AlexClaw.ControlPlane.Effects do
  @moduledoc """
  The catalogued actions that are not one database change: runs, downloads,
  skill files and loading, the database restore, recordings, the Google
  connection and the secret upgrade. `AlexClaw.ControlPlane.perform/3` starts
  each once its audit row is written (`AlexClaw.ControlPlane.Actions.kind/1`);
  nothing else calls these.
  """

  alias AlexClaw.Auth.RunApproval
  alias AlexClaw.Config.SecretUpgrade
  alias AlexClaw.Database.{DataExport, Dump, Restore}
  alias AlexClaw.Google.OAuth
  alias AlexClaw.{Resources, Workflows}
  alias AlexClaw.Skills.{CodeGenerator, Invoke, WebAutomation}
  alias AlexClaw.WebAutomation.Recording
  alias AlexClaw.Workflows.{Executor, SkillRegistry, Workflow}

  @effects [
    :run_workflow,
    :run_protected_workflow,
    :run_skill,
    :run_privileged_skill,
    :download_database,
    :export_data,
    :export_workflow,
    :stage_skill,
    :load_skill,
    :unload_skill,
    :generate_skill,
    :restore_data,
    :record,
    :replay,
    :connect_google,
    :disconnect_google,
    :upgrade_secrets
  ]

  @doc "The actions that are effects."
  @spec actions() :: [atom()]
  def actions, do: @effects

  @doc "Run the effect `action` with `params`."
  @spec run(atom(), map()) :: {:ok, term()} | {:ok, term(), atom()} | {:error, term()} | term()

  # --- runs. An unprotected run needs no second factor; a protected one is
  # :run_protected_workflow, approved by a code for that workflow, this run.

  def run(:run_workflow, %{workflow_id: id} = params) do
    with {:ok, workflow} <- Workflows.get_workflow(id),
         :ok <- runnable(workflow),
         :ok <- unprotected(Workflow.protected?(workflow)),
         do: start(workflow, params)
  end

  def run(:run_protected_workflow, %{workflow_id: id} = params) do
    with {:ok, workflow} <- Workflows.get_workflow(id),
         :ok <- runnable(workflow) do
      approval = RunApproval.grant(id)

      Task.Supervisor.start_child(AlexClaw.TaskSupervisor, fn ->
        Executor.run(id, approval: approval, privileged: Map.get(params, :privileged) == true)
      end)

      {:ok, {:started, workflow}}
    end
  end

  def run(:run_skill, %{caller: caller, skill: skill, args: args} = params),
    do: Invoke.run(caller, skill, args, Map.get(params, :opts, []))

  def run(:run_privileged_skill, %{skill: skill, args: args}),
    do: Invoke.run_privileged(skill, args)

  # --- data

  def run(:download_database, %{acc: acc, open: open, emit: emit}),
    do: {:ok, Dump.write(open.(acc), emit)}

  def run(:export_data, %{acc: acc, open: open, emit: emit}),
    do: {:ok, DataExport.write(open.(acc), emit)}

  def run(:export_workflow, %{workflow_id: id}) do
    with {:ok, workflow} <- Workflows.get_workflow(id),
         do: {:ok, {workflow, Workflows.export_workflow(workflow)}}
  end

  # Arbitrary SQL against the live database, approved by a code for this
  # restore. The staged file is consumed either way: Restore.run/2 deletes it.
  def run(:restore_data, %{path: path, filename: filename, session: session}) do
    {status, message} = Restore.run(path, %{filename: filename, session: session})

    Phoenix.PubSub.broadcast(
      AlexClaw.PubSub,
      "database:restore",
      {:restore_finished, status, message}
    )

    {status, message}
  end

  # --- skills. An upload is staged under skills_dir/pending, never the live
  # directory; loading it approves that file's code.

  def run(:stage_skill, %{path: path, name: name}), do: SkillRegistry.stage_upload(path, name)

  def run(:load_skill, %{name: name, reload: true}), do: SkillRegistry.reload_skill(name)

  def run(:load_skill, %{file_path: file_path} = params) do
    with {:ok, _promoted} <- promoted(SkillRegistry.promote_pending(file_path)),
         do: SkillRegistry.load_skill(file_path, load_opts(params[:origin]))
  end

  def run(:unload_skill, %{name: name}) do
    with :ok <- SkillRegistry.unload_skill(name), do: {:ok, name}
  end

  # One generation attempt: the first generates, the ones after repair what
  # the last one wrote.
  def run(
        :generate_skill,
        %{goal: goal, skill_name: name, context: context, provider: provider} = params
      ),
      do: generate(goal, name, context, provider, params[:last])

  # --- recordings

  def run(:record, %{stop: session_id}) do
    with {:ok, result} <- WebAutomation.stop_recording(session_id),
         {:ok, recipe} <- recipe(result) do
      Resources.create_resource(%{
        name: "Recording #{session_id}",
        type: "automation",
        url: recipe["url"],
        metadata: recipe
      })
    end
  end

  def run(:record, %{url: url}), do: %{"url" => url} |> WebAutomation.record() |> played()

  def run(:replay, %{resource_id: id}) do
    with {:ok, resource} <- Resources.get_resource(id),
         :ok <- automation(resource),
         do: resource |> replay_config() |> WebAutomation.play([]) |> played()
  end

  # --- the Google connection: the authorisation is issued to one signed-in
  # session and redeemed by that session alone.

  def run(:connect_google, %{step: :start, owner: owner}), do: OAuth.generate_auth_url(owner)

  def run(:connect_google, %{step: :finish, code: code, state: state, owner: owner}),
    do: OAuth.handle_callback(code, state, owner)

  def run(:disconnect_google, _params) do
    with :ok <- OAuth.disconnect(), do: {:ok, :disconnected}
  end

  # --- the one-time move of secrets into OpenBao, at boot

  def run(:upgrade_secrets, params), do: SecretUpgrade.run(Map.get(params, :opts, []))

  defp runnable(%Workflow{enabled: false}), do: {:error, :workflow_disabled}
  defp runnable(_workflow), do: :ok

  defp unprotected(true), do: {:error, :protected_workflow}
  defp unprotected(false), do: :ok

  # MCP waits for the run and answers with its result; the admin UI, a chat
  # and a webhook start it and are told so. An input is the first step's.
  defp start(workflow, %{wait: true} = params), do: execute(workflow.id, params[:input])

  # Another node's request: the run carries where it came from, which the
  # receive_from_workflow gate checks again at step 1.
  defp start(workflow, %{from_node: node} = params) do
    Task.Supervisor.start_child(AlexClaw.TaskSupervisor, fn ->
      Executor.run_remote_trigger(workflow.id, params[:input], %{"_source_node" => node})
    end)

    {:ok, {:started, workflow}}
  end

  defp start(workflow, params) do
    Task.Supervisor.start_child(AlexClaw.TaskSupervisor, fn ->
      execute(workflow.id, params[:input])
    end)

    {:ok, {:started, workflow}}
  end

  defp execute(id, nil), do: Executor.run(id)
  defp execute(id, input), do: Executor.run_with_initial_input(id, input)

  defp promoted({:error, _reason} = refused), do: refused
  defp promoted(promoted), do: {:ok, promoted}

  defp load_opts(:generated), do: [origin: "generated", approval: "totp"]
  defp load_opts(_origin), do: [origin: "upload", approval: "totp"]

  defp generate(goal, name, context, provider, nil),
    do: CodeGenerator.generate_step(goal, name, context, provider, nil)

  defp generate(goal, name, context, provider, last),
    do: CodeGenerator.retry_step(goal, name, context, provider, last)

  # A credential field the sidecar recorded as a slot stays one: a login to
  # attach on the Resources page.
  defp recipe(result) do
    base_url = (result["summary"] || %{})["base_url"]
    Recording.to_recipe(base_url, result["actions"] || [])
  end

  defp played({:ok, text, _branch}), do: {:ok, text}
  defp played({:error, _reason} = failed), do: failed

  defp automation(%{type: "automation"}), do: :ok
  defp automation(_resource), do: {:error, :not_an_automation}

  # A resource's own url fills in for a config that does not carry one.
  defp replay_config(%{url: url, metadata: metadata}) when is_binary(url),
    do: fill_url(metadata || %{}, url)

  defp replay_config(%{metadata: metadata}), do: metadata || %{}

  defp fill_url(%{"url" => url} = config, _fallback) when url not in [nil, false], do: config
  defp fill_url(config, url), do: Map.put(config, "url", url)
end
