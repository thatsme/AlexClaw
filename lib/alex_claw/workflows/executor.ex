defmodule AlexClaw.Workflows.Executor do
  @moduledoc """
  Executes a workflow by walking its step graph. Supports conditional branching:
  each skill returns a branch atom, and the executor follows the matching route
  to the next step. Steps without routes fall through to the next position
  (backward compatible with linear workflows).
  """
  require Logger

  alias AlexClaw.Auth.{CapabilityToken, SafeExecutor}
  alias AlexClaw.ContentSanitizer
  alias AlexClaw.Skills.CircuitBreaker
  alias AlexClaw.Workflows
  alias AlexClaw.Workflows.{Registry, SkillRegistry}

  @doc "Run a workflow by ID. Creates a run record and walks the step graph."
  @spec run(integer()) ::
          {:ok, AlexClaw.Workflows.WorkflowRun.t()}
          | {:error, atom() | AlexClaw.Workflows.WorkflowRun.t()}
  def run(workflow_id) do
    workflow = Workflows.get_workflow!(workflow_id)

    if workflow.enabled do
      execute(workflow, %{})
    else
      {:error, :workflow_disabled}
    end
  end

  @doc "Run a workflow with externally-provided initial input (used by cluster remote triggers)."
  @spec run_with_input(integer(), any(), map()) ::
          {:ok, AlexClaw.Workflows.WorkflowRun.t()}
          | {:error, atom() | AlexClaw.Workflows.WorkflowRun.t()}
  def run_with_input(workflow_id, initial_input, extra_config \\ %{}) do
    workflow = Workflows.get_workflow!(workflow_id)

    if workflow.enabled do
      execute(workflow, %{remote_input: initial_input, remote_extra_config: extra_config})
    else
      {:error, :workflow_disabled}
    end
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
      max_iterations: length(steps) * 2,
      remote_input: Map.get(remote_data, :remote_input),
      remote_extra_config: Map.get(remote_data, :remote_extra_config, %{})
    }

    ctx = %{steps: steps, workflow: workflow, run: run}

    first_position(steps)
    |> walk(ctx, state)
    |> finish(ctx, gateways)
  end

  defp finish({:ok, final_result, step_results}, ctx, _gateways) do
    {:ok, run} =
      Workflows.update_run(ctx.run, %{
        status: "completed",
        completed_at: DateTime.utc_now(),
        result: %{"output" => serialize_result(final_result)},
        step_results: step_results
      })

    Registry.deregister(run.id)

    Registry.broadcast(
      {:workflow_run_completed,
       %{run_id: run.id, workflow_id: ctx.workflow.id, workflow_name: ctx.workflow.name}}
    )

    Logger.info("Workflow '#{ctx.workflow.name}' completed (run #{run.id})",
      workflow: ctx.workflow.name
    )

    {:ok, run}
  end

  defp finish({:error, step_name, reason, step_results}, ctx, gateways) do
    {:ok, run} =
      Workflows.update_run(ctx.run, %{
        status: "failed",
        completed_at: DateTime.utc_now(),
        error: inspect(reason),
        step_results: step_results
      })

    Registry.deregister(run.id)

    Registry.broadcast(
      {:workflow_run_failed,
       %{
         run_id: run.id,
         workflow_id: ctx.workflow.id,
         workflow_name: ctx.workflow.name,
         error: inspect(reason)
       }}
    )

    Logger.error(
      "Workflow '#{ctx.workflow.name}' failed at step '#{step_name}': #{inspect(reason)}",
      workflow: ctx.workflow.name
    )

    notify_failure_if_any(gateways, ctx.workflow, step_name, reason)
    {:error, run}
  end

  defp notify_failure_if_any([], _workflow, _step_name, _reason), do: :ok

  defp notify_failure_if_any(gateways, workflow, step_name, reason) do
    notify_failure(workflow, step_name, reason, gateways)
  end

  # --- Graph Walker ---

  defp walk(nil, _steps, _workflow, _run, state) do
    # No more steps — workflow complete
    last_result = last_output(state)
    {:ok, last_result, state.step_results}
  end

  defp walk(_pos, _steps, _workflow, _run, %{max_iterations: 0} = state) do
    {:error, "loop_protection", :loop_detected, state.step_results}
  end

  # steps, workflow and run are invariant for the whole walk, so they travel as
  # one context rather than as three parameters threaded through every clause.
  defp walk(pos, ctx, state) do
    ctx.steps
    |> find_step(pos)
    |> visit(pos, ctx, state)
  end

  # Position resolved to nothing — the graph has run out of steps.
  defp visit(nil, _pos, _ctx, state), do: {:ok, last_output(state), state.step_results}

  defp visit(step, pos, ctx, state) do
    enter(MapSet.member?(state.visited, pos), step, pos, ctx, state)
  end

  defp enter(true, step, _pos, _ctx, state) do
    {:error, step.name, :loop_detected, state.step_results}
  end

  defp enter(false, step, pos, ctx, state) do
    state = %{
      state
      | visited: MapSet.put(state.visited, pos),
        max_iterations: state.max_iterations - 1
    }

    {input, step} =
      inject_remote_input(step, resolve_step_input(step, ctx.steps, state.outputs), state)

    announce_step(step, ctx)

    started_at = System.monotonic_time(:millisecond)
    step_result = execute_step(step, input, ctx.workflow, ctx.run)

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
    walk(resolve_next(step, branch, ctx.steps), ctx, state)
  end

  defp advance({:skipped, result}, step, ctx, state) do
    state = record_step_result(state, step, result, :skipped)
    walk(next_position(step.position, ctx.steps), ctx, state)
  end

  defp advance({:error, reason}, step, ctx, state) do
    state = record_step_error(state, step, reason)
    route_error(resolve_next(step, :on_error, ctx.steps), step, reason, ctx, state)
  end

  defp route_error(nil, step, reason, _ctx, state) do
    {:error, step.name, reason, state.step_results}
  end

  # Routed to another step — the error is exposed in outputs so that step can read it.
  defp route_error(next_pos, step, reason, ctx, state) do
    state = %{state | outputs: Map.put(state.outputs, step.position, %{error: reason})}
    walk(next_pos, ctx, state)
  end

  # --- Step Execution ---

  defp execute_step(step, input, workflow, run) do
    args = %{
      input: input,
      resources: workflow.resources,
      config: step.config || %{},
      workflow_run_id: run.id,
      llm_provider: step.llm_model || workflow.default_provider,
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

  defp resolve_next(step, branch, steps) do
    route_for(step.routes, step, branch, steps)
  end

  # No routes defined — fall through to the next position on success and halt on
  # error, which is how linear workflows behaved before branching existed.
  defp route_for(routes, step, branch, steps) when routes == [] or is_nil(routes) do
    if branch == :on_error, do: nil, else: next_position(step.position, steps)
  end

  defp route_for(routes, _step, branch, _steps) do
    branch_str = to_string(branch)

    routes
    |> Enum.find(&(&1["branch"] == branch_str))
    |> matched_route(routes)
  end

  defp matched_route(%{"goto" => pos}, _routes), do: pos

  # No matching route — fall back to the default branch if one is defined.
  defp matched_route(nil, routes) do
    case Enum.find(routes, &(&1["branch"] == "default")) do
      %{"goto" => pos} -> pos
      nil -> nil
    end
  end

  # --- Input Resolution ---

  defp resolve_step_input(step, steps, outputs) do
    case step.input_from do
      nil ->
        prev =
          steps
          |> Enum.filter(&(&1.position < step.position))
          |> Enum.max_by(& &1.position, fn -> nil end)

        if prev, do: Map.get(outputs, prev.position), else: nil

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
      "❌ *#{workflow.name}* failed at _#{step_name}_\n`#{String.slice(inspect(reason), 0, 200)}`"

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
