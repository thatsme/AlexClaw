defmodule AlexClaw.Workflows.Executor do
  @moduledoc """
  Executes a workflow by walking its step graph. Supports conditional branching:
  each skill returns a branch atom, and the executor follows the matching route
  to the next step. Steps without routes fall through to the next position
  (backward compatible with linear workflows).
  """
  require Logger

  alias AlexClaw.Workflows
  alias AlexClaw.Workflows.{Registry, SkillRegistry}
  alias AlexClaw.Skills.CircuitBreaker
  alias AlexClaw.Auth.{CapabilityToken, SafeExecutor}

  @doc "Run a workflow by ID. Creates a run record and walks the step graph."
  @spec run(integer()) :: {:ok, AlexClaw.Workflows.WorkflowRun.t()} | {:error, atom() | AlexClaw.Workflows.WorkflowRun.t()}
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
          {:ok, AlexClaw.Workflows.WorkflowRun.t()} | {:error, atom() | AlexClaw.Workflows.WorkflowRun.t()}
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
      {:workflow_run_started, %{run_id: run.id, workflow_id: workflow.id, workflow_name: workflow.name, started_at: run.started_at}}
    )

    state = %{
      outputs: %{},
      step_results: %{},
      visited: MapSet.new(),
      max_iterations: length(steps) * 2,
      remote_input: Map.get(remote_data, :remote_input),
      remote_extra_config: Map.get(remote_data, :remote_extra_config, %{})
    }

    case walk(first_position(steps), steps, workflow, run, state) do
      {:ok, final_result, step_results} ->
        {:ok, run} =
          Workflows.update_run(run, %{
            status: "completed",
            completed_at: DateTime.utc_now(),
            result: %{"output" => serialize_result(final_result)},
            step_results: step_results
          })

        Registry.deregister(run.id)
        Registry.broadcast({:workflow_run_completed, %{run_id: run.id, workflow_id: workflow.id, workflow_name: workflow.name}})
        Logger.info("Workflow '#{workflow.name}' completed (run #{run.id})", workflow: workflow.name)
        {:ok, run}

      {:error, step_name, reason, step_results} ->
        {:ok, run} =
          Workflows.update_run(run, %{
            status: "failed",
            completed_at: DateTime.utc_now(),
            error: inspect(reason),
            step_results: step_results
          })

        Registry.deregister(run.id)
        Registry.broadcast({:workflow_run_failed, %{run_id: run.id, workflow_id: workflow.id, workflow_name: workflow.name, error: inspect(reason)}})
        Logger.error("Workflow '#{workflow.name}' failed at step '#{step_name}': #{inspect(reason)}", workflow: workflow.name)
        if gateways != [], do: notify_failure(workflow, step_name, reason, gateways)
        {:error, run}
    end
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

  defp walk(pos, steps, workflow, run, state) do
    step = find_step(steps, pos)

    if step do
      if MapSet.member?(state.visited, pos) do
        {:error, step.name, :loop_detected, state.step_results}
      else
        state = %{state | visited: MapSet.put(state.visited, pos), max_iterations: state.max_iterations - 1}
        input = resolve_step_input(step, steps, state.outputs)

        # Inject remote data for receive_from_workflow gate
        {input, step} =
          if step.skill == "receive_from_workflow" and state.remote_input != nil do
            # Remote config goes first so step config takes precedence
            merged_config = Map.merge(state.remote_extra_config, step.config || %{})
            {state.remote_input, %{step | config: merged_config}}
          else
            {input, step}
          end

        Registry.update_step(run.id, step.name)
        Registry.broadcast(
          {:workflow_step_started, %{run_id: run.id, workflow_name: workflow.name, step_name: step.name, step_position: step.position}}
        )
        Logger.info("Executing step #{step.position}: #{step.name} (skill: #{step.skill})", workflow: workflow.name)

        started_at = System.monotonic_time(:millisecond)
        step_result = execute_step(step, input, workflow, run)
        duration_ms = System.monotonic_time(:millisecond) - started_at

        record_outcome(run.id, step, step_result, duration_ms)

        case step_result do
          {:ok, result, branch} ->
            Registry.broadcast(
              {:workflow_step_completed, %{run_id: run.id, workflow_name: workflow.name, step_name: step.name, step_position: step.position, branch: branch}}
            )

            state = record_step_result(state, step, result, branch)
            next = resolve_next(step, branch, steps)
            walk(next, steps, workflow, run, state)

          {:skipped, result} ->
            state = record_step_result(state, step, result, :skipped)
            next = next_position(step.position, steps)
            walk(next, steps, workflow, run, state)

          {:error, reason} ->
            state = record_step_error(state, step, reason)
            next = resolve_next(step, :on_error, steps)

            case next do
              nil ->
                {:error, step.name, reason, state.step_results}

              next_pos ->
                # Error is routed to another step — store error info in outputs for that step's input
                state = %{state | outputs: Map.put(state.outputs, step.position, %{error: reason})}
                walk(next_pos, steps, workflow, run, state)
            end
        end
      end
    else
      {:ok, last_output(state), state.step_results}
    end
  end

  # --- Step Execution ---

  defp execute_step(step, input, workflow, run) do
    provider = step.llm_model || workflow.default_provider

    args = %{
      input: input,
      resources: workflow.resources,
      config: step.config || %{},
      workflow_run_id: run.id,
      llm_provider: provider,
      llm_tier: step.llm_tier,
      prompt_template: step.prompt_template
    }

    Process.put(:auth_chain_depth, 0)

    case SkillRegistry.resolve(step.skill) do
      {:ok, module} ->
        skill_type = SkillRegistry.get_type(module) || :dynamic
        token = mint_step_token(module, skill_type)
        if token, do: Process.put(:auth_token, token)

        result =
          CircuitBreaker.call(step.skill, fn ->
            SafeExecutor.run(module, args, skill_type, token, [])
          end)

        case result do
          {:ok, result, branch} -> {:ok, result, branch}
          {:ok, result} -> {:ok, result, :on_success}
          {:error, :circuit_open} -> handle_circuit_open(step, args)
          {:error, reason} -> {:error, reason}
        end

      {:error, :unknown_skill} ->
        handle_missing_skill(step, args)
    end
  end

  defp handle_circuit_open(step, args) do
    case get_in(step.config, ["on_circuit_open"]) do
      "skip" ->
        Logger.warning("[CircuitBreaker] Skipping step #{step.name}, circuit open for #{step.skill}")
        {:skipped, args.input}

      "fallback" ->
        fallback_name = get_in(step.config, ["fallback_skill"])

        case SkillRegistry.resolve(fallback_name) do
          {:ok, mod} ->
            case mod.run(args) do
              {:ok, result, branch} -> {:ok, result, branch}
              {:ok, result} -> {:ok, result, :on_success}
              {:error, reason} -> {:error, reason}
            end

          {:error, :unknown_skill} ->
            {:error, {:fallback_not_found, fallback_name}}
        end

      _halt_or_nil ->
        {:error, :circuit_open}
    end
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
    case step.routes do
      routes when routes == [] or is_nil(routes) ->
        # No routes defined — fall through to next position on success,
        # halt on error (backward compatible)
        if branch == :on_error, do: nil, else: next_position(step.position, steps)

      routes ->
        branch_str = to_string(branch)

        case Enum.find(routes, &(&1["branch"] == branch_str)) do
          %{"goto" => pos} ->
            pos

          nil ->
            # No matching route — check for default
            case Enum.find(routes, &(&1["branch"] == "default")) do
              %{"goto" => pos} -> pos
              nil -> nil
            end
        end
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
    step_names = workflow.steps |> Enum.map(& &1.name) |> Enum.join(" → ")
    msg = "⚙️ *#{workflow.name}* started\n#{step_names}"
    Enum.each(gateways, fn gw -> gw.send_message(msg, []) end)
  end

  defp notify_failure(workflow, step_name, reason, gateways) do
    msg = "❌ *#{workflow.name}* failed at _#{step_name}_\n`#{String.slice(inspect(reason), 0, 200)}`"
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
