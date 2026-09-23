defmodule AlexClaw.Workflows.Executor do
  @moduledoc """
  Executes a workflow by walking its step graph. Each skill returns a branch,
  and the executor follows the matching route.

  One rule, with or without routes. A branch with a route goes where the route
  says: a position, or `"end"`. An unrouted branch does what its kind implies:
  an error fails the run, `on_empty` ends it completed, anything else goes to
  the next step. A route to a position that does not exist fails the run. A run
  in which an error was handled by a route ends `recovered`. Every failure
  names the step, and a step that raises fails the run like any other error.
  """
  require Logger

  alias AlexClaw.Auth.{CapabilityToken, RunApproval, SafeExecutor}
  alias AlexClaw.ContentSanitizer
  alias AlexClaw.Skills.CircuitBreaker
  alias AlexClaw.Workflows
  alias AlexClaw.Workflows.{Registry, SkillRegistry, Workflow}

  @doc """
  Run a workflow by ID. Creates a run record and walks the step graph.

  A workflow that requires 2FA runs only with `opts[:approval]`, a live
  `AlexClaw.Auth.RunApproval` for it, consumed here; otherwise
  `{:error, :approval_required}` and no run is created.
  """
  @spec run(integer(), keyword()) ::
          {:ok, AlexClaw.Workflows.WorkflowRun.t()}
          | {:error, atom() | AlexClaw.Workflows.WorkflowRun.t()}
  def run(workflow_id, opts \\ []) do
    workflow_id
    |> Workflows.get_workflow!()
    |> launch(%{}, opts)
  end

  @doc """
  Run a workflow started by another node's `send_to_workflow`. `remote_input`
  and `extra_config` reach only a `receive_from_workflow` step — this is the
  cluster path and nothing else. To hand input to the first step, use
  `run_with_initial_input/3`. Approval as for `run/2`.
  """
  @spec run_remote_trigger(integer(), any(), map(), keyword()) ::
          {:ok, AlexClaw.Workflows.WorkflowRun.t()}
          | {:error, atom() | AlexClaw.Workflows.WorkflowRun.t()}
  def run_remote_trigger(workflow_id, initial_input, extra_config, opts \\ []) do
    workflow_id
    |> Workflows.get_workflow!()
    |> launch(%{remote_input: initial_input, remote_extra_config: extra_config}, opts)
  end

  @doc """
  Run a workflow whose first step takes `input` as its input (`args[:input]`) —
  a GitHub webhook event, an MCP tool's input. Unlike `run_remote_trigger/4`,
  which feeds only a `receive_from_workflow` step, the input reaches whatever the
  first step is. Approval as for `run/2`.
  """
  @spec run_with_initial_input(integer(), term(), keyword()) ::
          {:ok, AlexClaw.Workflows.WorkflowRun.t()}
          | {:error, atom() | AlexClaw.Workflows.WorkflowRun.t()}
  def run_with_initial_input(workflow_id, input, opts \\ []) do
    workflow_id
    |> Workflows.get_workflow!()
    |> launch(%{initial_input: input}, opts)
  end

  # Every entry point comes through here: disabled first, then — for a workflow
  # that requires 2FA — the approval, before any run row exists.
  defp launch(%Workflow{enabled: false}, _data, _opts), do: {:error, :workflow_disabled}

  defp launch(workflow, data, opts) do
    workflow
    |> approval(Keyword.get(opts, :approval))
    |> approved(workflow, data)
  end

  defp approval(workflow, approval) do
    if Workflow.protected?(workflow), do: RunApproval.consume(approval, workflow.id), else: :ok
  end

  defp approved(:ok, workflow, data), do: execute(workflow, data)

  defp approved(:error, workflow, _data) do
    Logger.warning(
      "Workflow '#{workflow.name}' requires a person's approval for each run; refused without one",
      workflow: workflow.name
    )

    {:error, :approval_required}
  end

  defp execute(workflow, remote_data) do
    node_name = to_string(node())
    {:ok, run} = Workflows.create_run(workflow, %{node: node_name})
    Registry.register(run.id, self(), workflow.id, workflow.name)
    Process.put(:auth_workflow_run_id, run.id)
    steps = workflow.steps
    gateways = workflow_gateways(steps)

    Logger.info(
      "Workflow '#{workflow.name}' started (run #{run.id}), #{length(steps)} steps, " <>
        "provider: #{workflow.default_provider || "auto"}",
      workflow: workflow.name
    )

    if gateways != [], do: notify_start(workflow, gateways)

    Registry.broadcast(
      {:workflow_run_started,
       %{
         run_id: run.id,
         workflow_id: workflow.id,
         workflow_name: workflow.name,
         started_at: run.started_at
       }}
    )

    state = %{
      outputs: %{},
      step_results: %{},
      visited: MapSet.new(),
      recovered: false,
      remote_input: Map.get(remote_data, :remote_input),
      remote_extra_config: Map.get(remote_data, :remote_extra_config, %{}),
      initial_input: Map.get(remote_data, :initial_input)
    }

    ctx = %{steps: steps, workflow: workflow, run: run}

    steps
    |> first_position()
    |> start(ctx, state)
    |> finish(ctx, gateways)
  end

  defp start(nil, _ctx, state), do: done(state)
  defp start(pos, ctx, state), do: walk(pos, ctx, state)

  defp done(state), do: {:ok, last_output(state), state}

  defp finish({:ok, final_result, state}, ctx, _gateways) do
    status = if state.recovered, do: "recovered", else: "completed"

    {:ok, run} =
      Workflows.update_run(ctx.run, %{
        status: status,
        completed_at: DateTime.utc_now(),
        result: %{"output" => serialize_result(final_result)},
        step_results: state.step_results
      })

    Registry.deregister(run.id)

    Registry.broadcast(
      {finished_event(status),
       %{run_id: run.id, workflow_id: ctx.workflow.id, workflow_name: ctx.workflow.name}}
    )

    Logger.info("Workflow '#{ctx.workflow.name}' #{status} (run #{run.id})",
      workflow: ctx.workflow.name
    )

    {:ok, run}
  end

  defp finish({:error, step_name, reason, step_results}, ctx, gateways) do
    error = failure_text(step_name, reason)

    {:ok, run} =
      Workflows.update_run(ctx.run, %{
        status: "failed",
        completed_at: DateTime.utc_now(),
        error: error,
        step_results: step_results
      })

    Registry.deregister(run.id)

    Registry.broadcast(
      {:workflow_run_failed,
       %{
         run_id: run.id,
         workflow_id: ctx.workflow.id,
         workflow_name: ctx.workflow.name,
         error: error
       }}
    )

    Logger.error("Workflow '#{ctx.workflow.name}' failed: #{error}", workflow: ctx.workflow.name)

    notify_failure_if_any(gateways, ctx.workflow, step_name, reason)
    {:error, run}
  end

  defp notify_failure_if_any([], _workflow, _step_name, _reason), do: :ok

  defp notify_failure_if_any(gateways, workflow, step_name, reason) do
    notify_failure(workflow, step_name, reason, gateways)
  end

  # Every failure names the step it happened at.
  defp failure_text(step_name, reason), do: "step '#{step_name}': #{inspect(reason)}"

  defp finished_event("recovered"), do: :workflow_run_recovered
  defp finished_event("completed"), do: :workflow_run_completed

  # --- Graph Walker ---

  # steps, workflow and run are invariant for the whole walk, so they travel as
  # one context rather than as three parameters threaded through every clause.
  # `pos` always names an existing step: go/4 checks a route's target first.
  defp walk(pos, ctx, state) do
    enter(MapSet.member?(state.visited, pos), find_step(ctx.steps, pos), pos, ctx, state)
  end

  # Where a step sends the walk next (see resolve_next/2).
  defp go(:end, _step, _ctx, state), do: done(state)

  defp go(:next, step, ctx, state),
    do: step.position |> next_position(ctx.steps) |> start(ctx, state)

  defp go({:goto, pos}, step, ctx, state) do
    go_to(find_step(ctx.steps, pos), pos, step, ctx, state)
  end

  defp go_to(nil, pos, step, _ctx, state),
    do: {:error, step.name, {:route_target_missing, pos}, state.step_results}

  defp go_to(_target, pos, _step, ctx, state), do: walk(pos, ctx, state)

  defp enter(true, step, _pos, _ctx, state) do
    {:error, step.name, :loop_detected, state.step_results}
  end

  defp enter(false, step, pos, ctx, state) do
    state = %{state | visited: MapSet.put(state.visited, pos)}

    {input, step} =
      inject_remote_input(
        step,
        resolve_step_input(step, ctx.steps, state.outputs, state.initial_input),
        state
      )

    announce_step(step, ctx)

    started_at = System.monotonic_time(:millisecond)
    step_result = contained_step(step, input, ctx.workflow, ctx.run)

    record_outcome(
      ctx.run.id,
      step,
      step_result,
      System.monotonic_time(:millisecond) - started_at
    )

    advance(step_result, step, ctx, state)
  end

  # The receive_from_workflow gate takes its input from the remote trigger rather
  # than from the previous step. Remote config goes first so step config wins.
  defp inject_remote_input(%{skill: "receive_from_workflow"} = step, input, state) do
    remote_input(state.remote_input, step, input, state)
  end

  defp inject_remote_input(step, input, _state), do: {input, step}

  defp remote_input(nil, step, input, _state), do: {input, step}

  defp remote_input(remote, step, _input, state) do
    {remote, %{step | config: Map.merge(state.remote_extra_config, step.config || %{})}}
  end

  defp announce_step(step, ctx) do
    Registry.update_step(ctx.run.id, step.name)

    Registry.broadcast(
      {:workflow_step_started,
       %{
         run_id: ctx.run.id,
         workflow_name: ctx.workflow.name,
         step_name: step.name,
         step_position: step.position
       }}
    )

    Logger.info("Executing step #{step.position}: #{step.name} (skill: #{step.skill})",
      workflow: ctx.workflow.name
    )
  end

  defp advance({:ok, result, branch}, step, ctx, state) do
    Registry.broadcast(
      {:workflow_step_completed,
       %{
         run_id: ctx.run.id,
         workflow_name: ctx.workflow.name,
         step_name: step.name,
         step_position: step.position,
         branch: branch
       }}
    )

    state = record_step_result(state, step, result, branch)
    go(resolve_next(step, branch), step, ctx, state)
  end

  defp advance({:skipped, result}, step, ctx, state) do
    state = record_step_result(state, step, result, :skipped)
    go(:next, step, ctx, state)
  end

  defp advance({:error, reason}, step, ctx, state) do
    state = record_step_error(state, step, reason)
    route_error(resolve_next(step, :on_error), step, reason, ctx, state)
  end

  defp route_error(:fail, step, reason, _ctx, state) do
    {:error, step.name, reason, state.step_results}
  end

  # Handled by a route: the run can still finish, as recovered, and the error is
  # exposed in outputs so the step it goes to can read it.
  defp route_error(target, step, reason, ctx, state) do
    state = %{
      state
      | outputs: Map.put(state.outputs, step.position, %{error: reason}),
        recovered: true
    }

    go(target, step, ctx, state)
  end

  # --- Step Execution ---

  @doc """
  The provider a step's LLM calls use: the step's own model, unless it is
  unset or `"auto"` — the provider select's default — in which case the
  workflow's.
  """
  @spec provider_for(map(), map()) :: String.t() | nil
  def provider_for(%{llm_model: model}, workflow) when model in [nil, "", "auto"],
    do: workflow.default_provider

  def provider_for(%{llm_model: model}, _workflow), do: model

  # The boundary between a skill and the run: whatever a step raises, throws or
  # exits with fails that step, like any error, instead of escaping the executor
  # and leaving the run recorded as running.
  defp contained_step(step, input, workflow, run) do
    execute_step(step, input, workflow, run)
  rescue
    exception -> {:error, {:raised, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp execute_step(step, input, workflow, run) do
    args = %{
      input: input,
      resources: workflow.resources,
      config: step.config || %{},
      workflow_run_id: run.id,
      llm_provider: provider_for(step, workflow),
      llm_tier: step.llm_tier,
      prompt_template: step.prompt_template
    }

    Process.put(:auth_chain_depth, 0)
    run_resolved_skill(SkillRegistry.resolve(step.skill), step, args)
  end

  defp run_resolved_skill({:error, :unknown_skill}, step, args) do
    handle_missing_skill(step, args)
  end

  defp run_resolved_skill({:ok, module}, step, args) do
    skill_type = SkillRegistry.get_type(module) || :dynamic
    token = mint_step_token(module, skill_type)
    if token, do: Process.put(:auth_token, token)

    step.skill
    |> CircuitBreaker.call(fn ->
      SafeExecutor.run(module, args, skill_type, token, safe_opts(step))
    end)
    |> normalize_result()
    |> maybe_sanitize(step.skill)
    |> resolve_step_outcome(step, args)
  end

  defp safe_opts(step) do
    case get_in(step.config, ["timeout_ms"]) do
      timeout when is_integer(timeout) -> [timeout: timeout]
      _ -> []
    end
  end

  defp resolve_step_outcome({:ok, result, branch}, _step, _args), do: {:ok, result, branch}

  defp resolve_step_outcome({:error, :circuit_open}, step, args),
    do: handle_circuit_open(step, args)

  defp resolve_step_outcome({:error, reason}, _step, _args), do: {:error, reason}

  defp normalize_result({:ok, result, branch}), do: {:ok, result, branch}
  defp normalize_result({:ok, result}), do: {:ok, result, :on_success}
  defp normalize_result({:error, _} = err), do: err

  defp maybe_sanitize({:ok, result, branch}, skill_name) do
    if SkillRegistry.external?(skill_name) do
      {:ok, ContentSanitizer.sanitize(result, skill: skill_name), branch}
    else
      {:ok, result, branch}
    end
  end

  defp maybe_sanitize(error, _skill_name), do: error

  defp handle_circuit_open(step, args) do
    circuit_open_strategy(get_in(step.config, ["on_circuit_open"]), step, args)
  end

  defp circuit_open_strategy("skip", step, args) do
    Logger.warning("[CircuitBreaker] Skipping step #{step.name}, circuit open for #{step.skill}")
    {:skipped, args.input}
  end

  defp circuit_open_strategy("fallback", step, args) do
    fallback_name = get_in(step.config, ["fallback_skill"])
    run_fallback(SkillRegistry.resolve(fallback_name), fallback_name, args)
  end

  defp circuit_open_strategy(_halt_or_nil, _step, _args), do: {:error, :circuit_open}

  defp run_fallback({:error, :unknown_skill}, fallback_name, _args) do
    {:error, {:fallback_not_found, fallback_name}}
  end

  defp run_fallback({:ok, mod}, _fallback_name, args) do
    normalize_result(mod.run(args))
  end

  defp handle_missing_skill(step, args) do
    case get_in(step.config, ["on_missing_skill"]) do
      "skip" ->
        Logger.warning("[Executor] Skill #{step.skill} not found, skipping step #{step.name}")
        {:skipped, args.input}

      _ ->
        {:error, {:unknown_skill, step.skill}}
    end
  end

  # --- Route Resolution ---

  # :end, :next, {:goto, position} — or :fail for an error nothing handles. The
  # branch's own route first, then a "default" route, then the unrouted rule.
  defp resolve_next(step, branch) do
    routes = step.routes || []
    branch_str = to_string(branch)

    (Enum.find(routes, &(&1["branch"] == branch_str)) ||
       Enum.find(routes, &(&1["branch"] == "default")))
    |> target(branch)
  end

  defp target(%{"goto" => "end"}, _branch), do: :end
  defp target(%{"goto" => pos}, _branch), do: {:goto, pos}

  # Unrouted: an error fails the run; an empty result ends it, since nothing
  # downstream has anything to work on (a workflow that reports "nothing found"
  # routes on_empty); any other branch goes to the next step.
  defp target(nil, :on_error), do: :fail
  defp target(nil, :on_empty), do: :end
  defp target(nil, _branch), do: :next

  # --- Input Resolution ---

  # The first step has no previous output; it takes the run's initial input,
  # nil unless the run was started with one.
  defp resolve_step_input(step, steps, outputs, initial_input) do
    case step.input_from do
      nil ->
        prev =
          steps
          |> Enum.filter(&(&1.position < step.position))
          |> Enum.max_by(& &1.position, fn -> nil end)

        if prev, do: Map.get(outputs, prev.position), else: initial_input

      position ->
        Map.get(outputs, position)
    end
  end

  # --- Outcome Recording ---

  defp record_outcome(run_id, step, step_result, duration_ms) do
    output_snapshot = truncate_output(step_result)

    metadata =
      case step_result do
        {:error, reason} -> %{"error" => inspect(reason)}
        {:skipped, _} -> %{"skipped" => true}
        {:ok, _, branch} -> %{"branch" => to_string(branch)}
      end

    Workflows.record_outcome(%{
      workflow_run_id: run_id,
      step_position: step.position,
      skill_name: step.skill,
      duration_ms: duration_ms,
      output_snapshot: output_snapshot,
      metadata: metadata
    })
  end

  defp truncate_output({:ok, result, _branch}), do: do_truncate(result)
  defp truncate_output({:ok, result}), do: do_truncate(result)
  defp truncate_output({:skipped, _}), do: %{}
  defp truncate_output({:error, reason}), do: %{"error" => String.slice(inspect(reason), 0, 2048)}

  defp do_truncate(val) when is_binary(val), do: %{"output" => String.slice(val, 0, 2048)}
  defp do_truncate(%{} = val), do: %{"output" => String.slice(inspect(val), 0, 2048)}
  defp do_truncate(val), do: %{"output" => String.slice(inspect(val), 0, 2048)}

  # --- State Helpers ---

  defp record_step_result(state, step, result, branch) do
    step_results =
      Map.put(state.step_results, to_string(step.position), %{
        "name" => step.name,
        "skill" => step.skill,
        "branch" => to_string(branch),
        "output" => serialize_result(result)
      })

    outputs = Map.put(state.outputs, step.position, result)
    %{state | step_results: step_results, outputs: outputs}
  end

  defp record_step_error(state, step, reason) do
    step_results =
      Map.put(state.step_results, to_string(step.position), %{
        "name" => step.name,
        "skill" => step.skill,
        "error" => inspect(reason)
      })

    %{state | step_results: step_results}
  end

  defp find_step(steps, pos) do
    Enum.find(steps, &(&1.position == pos))
  end

  defp first_position([]), do: nil
  defp first_position(steps), do: hd(steps).position

  defp next_position(current, steps) do
    steps
    |> Enum.filter(&(&1.position > current))
    |> Enum.min_by(& &1.position, fn -> nil end)
    |> case do
      nil -> nil
      step -> step.position
    end
  end

  defp last_output(%{outputs: outputs}) when map_size(outputs) == 0, do: nil

  defp last_output(%{outputs: outputs}) do
    outputs
    |> Enum.max_by(&elem(&1, 0))
    |> elem(1)
  end

  # --- Token Minting ---

  defp mint_step_token(_module, :core), do: nil

  defp mint_step_token(module, :dynamic) do
    case SkillRegistry.get_permissions(module) do
      perms when is_list(perms) -> CapabilityToken.mint(perms)
      _ -> nil
    end
  end

  # --- Notifications ---

  defp notify_start(workflow, gateways) do
    step_names = Enum.map_join(workflow.steps, " → ", & &1.name)
    msg = "⚙️ *#{workflow.name}* started\n#{step_names}"
    Enum.each(gateways, fn gw -> gw.send_message(msg, []) end)
  end

  defp notify_failure(workflow, step_name, reason, gateways) do
    msg =
      "❌ *#{workflow.name}* failed at _#{step_name}_\n`#{AlexClaw.FailureText.describe(reason)}`"

    Enum.each(gateways, fn gw -> gw.send_message(msg, []) end)
  end

  # Detect which gateways a workflow targets based on its notify steps
  defp workflow_gateways(steps) do
    steps
    |> Enum.flat_map(fn step ->
      case step.skill do
        "telegram_notify" -> [AlexClaw.Gateway.Telegram]
        "discord_notify" -> [AlexClaw.Gateway.Discord]
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  # --- Serialization ---

  defp serialize_result(nil), do: nil
  defp serialize_result(val) when is_binary(val), do: val
  defp serialize_result(%{} = val), do: val
  defp serialize_result(val), do: inspect(val)
end
