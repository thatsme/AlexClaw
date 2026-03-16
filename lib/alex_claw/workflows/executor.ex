defmodule AlexClaw.Workflows.Executor do
  @moduledoc """
  Executes a workflow by running its steps in order, passing data between them.
  """
  require Logger

  alias AlexClaw.Workflows
  alias AlexClaw.Workflows.SkillRegistry

  @doc "Run a workflow by ID. Creates a run record and executes all steps sequentially."
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
    resources = workflow.resources
    steps = workflow.steps
    default_provider = workflow.default_provider
    notifies? = Enum.any?(steps, &(&1.skill == "telegram_notify"))

    Logger.info("Workflow '#{workflow.name}' started (run #{run.id}), #{length(steps)} steps, provider: #{default_provider || "auto"}")

    if notifies?, do: notify_start(workflow)

    case execute_steps(steps, resources, run, default_provider) do
      {:ok, final_result, step_results} ->
        {:ok, run} =
          Workflows.update_run(run, %{
            status: "completed",
            completed_at: DateTime.utc_now(),
            result: %{"output" => serialize_result(final_result)},
            step_results: step_results
          })

        Logger.info("Workflow '#{workflow.name}' completed (run #{run.id})")
        {:ok, run}

      {:error, step_name, reason, step_results} ->
        {:ok, run} =
          Workflows.update_run(run, %{
            status: "failed",
            completed_at: DateTime.utc_now(),
            error: inspect(reason),
            step_results: step_results
          })

        Logger.error("Workflow '#{workflow.name}' failed at step '#{step_name}': #{inspect(reason)}")
        if notifies?, do: notify_failure(workflow, step_name, reason)
        {:error, run}
    end
  end

  defp notify_start(workflow) do
    step_names = workflow.steps |> Enum.map(& &1.name) |> Enum.join(" → ")
    AlexClaw.Gateway.send_message("⚙️ *#{workflow.name}* started\n#{step_names}")
  end

  defp notify_failure(workflow, step_name, reason) do
    AlexClaw.Gateway.send_message("❌ *#{workflow.name}* failed at _#{step_name}_\n`#{String.slice(inspect(reason), 0, 200)}`")
  end

  defp execute_steps(steps, resources, run, default_provider) do
    Enum.reduce_while(steps, {:ok, nil, %{}, %{}}, fn step, {:ok, _last_output, step_results, outputs} ->
      Logger.info("Executing step #{step.position}: #{step.name} (skill: #{step.skill})")

      input = resolve_step_input(step, steps, outputs)

      case execute_step(step, input, resources, run, default_provider) do
        {:ok, result} ->
          step_results = Map.put(step_results, to_string(step.position), %{
            "name" => step.name,
            "skill" => step.skill,
            "output" => serialize_result(result)
          })

          outputs = Map.put(outputs, step.position, result)

          {:cont, {:ok, result, step_results, outputs}}

        {:error, reason} ->
          step_results = Map.put(step_results, to_string(step.position), %{
            "name" => step.name,
            "skill" => step.skill,
            "error" => inspect(reason)
          })

          {:halt, {:error, step.name, reason, step_results}}
      end
    end)
    |> case do
      {:ok, final, step_results, _outputs} -> {:ok, final, step_results}
      {:error, step_name, reason, step_results} -> {:error, step_name, reason, step_results}
    end
  end

  defp resolve_step_input(step, steps, outputs) do
    case step.input_from do
      nil ->
        prev = steps
          |> Enum.filter(&(&1.position < step.position))
          |> Enum.max_by(& &1.position, fn -> nil end)

        if prev, do: Map.get(outputs, prev.position), else: nil

      position ->
        Map.get(outputs, position)
    end
  end

  defp execute_step(step, input, resources, run, default_provider) do
    provider = step.llm_model || default_provider

    args = %{
      input: input,
      resources: resources,
      config: step.config || %{},
      workflow_run_id: run.id,
      llm_provider: provider,
      llm_tier: step.llm_tier,
      prompt_template: step.prompt_template
    }

    case SkillRegistry.resolve(step.skill) do
      {:ok, module} ->
        module.run(args)

      {:error, :unknown_skill} ->
        {:error, {:unknown_skill, step.skill}}
    end
  end

  defp serialize_result(nil), do: nil
  defp serialize_result(val) when is_binary(val), do: val
  defp serialize_result(%{} = val), do: val
  defp serialize_result(val), do: inspect(val)
end
