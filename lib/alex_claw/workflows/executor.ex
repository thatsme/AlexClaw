defmodule AlexClaw.Workflows.Executor do
  @moduledoc """
  Executes a workflow by walking its step graph. Supports conditional branching:
  each skill returns a branch atom, and the executor follows the matching route
  to the next step. Steps without routes fall through to the next position
  (backward compatible with linear workflows).
  """
  require Logger

  alias AlexClaw.Workflows
  alias AlexClaw.Workflows.SkillRegistry
  alias AlexClaw.Skills.CircuitBreaker

  @doc "Run a workflow by ID. Creates a run record and walks the step graph."
  @spec run(integer()) :: {:ok, AlexClaw.Workflows.WorkflowRun.t()} | {:error, atom() | AlexClaw.Workflows.WorkflowRun.t()}
  def run(workflow_id) do
    workflow = Workflows.get_workflow!(workflow_id)

    if workflow.enabled do
      execute(workflow)
    else
      {:error, :workflow_disabled}
    end
  end

  defp execute(workflow) do
    {:ok, run} = Workflows.create_run(workflow)
    steps = workflow.steps
    gateways = workflow_gateways(steps)

    Logger.info(
      "Workflow '#{workflow.name}' started (run #{run.id}), #{length(steps)} steps, " <>
        "provider: #{workflow.default_provider || "auto"}",
      workflow: workflow.name
    )

    if gateways != [], do: notify_start(workflow, gateways)

    state = %{
      outputs: %{},
      step_results: %{},
      visited: MapSet.new(),
      max_iterations: length(steps) * 2
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

    unless step do
      {:ok, last_output(state), state.step_results}
    else
      if MapSet.member?(state.visited, pos) do
        {:error, step.name, :loop_detected, state.step_results}
      else
        state = %{state | visited: MapSet.put(state.visited, pos), max_iterations: state.max_iterations - 1}
        input = resolve_step_input(step, steps, state.outputs)

        Logger.info("Executing step #{step.position}: #{step.name} (skill: #{step.skill})", workflow: workflow.name)

        case execute_step(step, input, workflow, run) do
          {:ok, result, branch} ->
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

    case SkillRegistry.resolve(step.skill) do
      {:ok, module} ->
        case CircuitBreaker.call(step.skill, fn -> module.run(args) end) do
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
