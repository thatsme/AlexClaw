defmodule AlexClaw.Skills.Coder do
  @moduledoc """
  Autonomous code generation skill. Uses the local LLM to generate
  dynamic skills from natural language goals, then loads them via SkillAPI.
  Delegates generation logic to `AlexClaw.Skills.CodeGenerator`.
  """
  @behaviour AlexClaw.Skill
  require Logger

  alias AlexClaw.Skills.{CodeGenerator, SkillAPI}

  @impl true
  @spec description() :: String.t()
  def description, do: "Generate dynamic skills from natural language goals using local LLM"

  @impl true
  @spec routes() :: [atom()]
  def routes, do: [:on_created, :on_workflow_created, :on_error]

  @impl true
  @spec permissions() :: :all
  def permissions, do: :all

  @impl true
  @spec step_fields() :: [atom()]
  def step_fields, do: [:config]

  @impl true
  @spec config_hint() :: String.t()
  def config_hint, do: ~s|{"goal": "describe what the skill should do", "create_workflow": false, "max_retries": 3}|

  @impl true
  @spec config_scaffold() :: map()
  def config_scaffold, do: %{"goal" => "", "create_workflow" => false, "max_retries" => 3}

  @impl true
  @spec config_presets() :: %{String.t() => map()}
  def config_presets do
    %{
      "BEAM stats" => %{"goal" => "a skill that returns the current BEAM process count and memory usage"},
      "With workflow" => %{"goal" => "a skill that checks disk space", "create_workflow" => true}
    }
  end

  @impl true
  @spec config_help() :: String.t()
  def config_help, do: "goal: natural language description of the skill to generate. create_workflow: if true, creates a workflow with the generated skill. max_retries: number of LLM retries on failure (default 3)."

  @default_max_retries 5

  @impl true
  @spec run(map()) :: {:ok, String.t(), atom()} | {:error, any()}
  def run(args) do
    input = args[:input] || args[:config]["goal"] || ""
    config = args[:config] || %{}

    if String.trim(input) == "" do
      {:error, :no_goal}
    else
      max_retries = config["max_retries"] || @default_max_retries
      skill_name = CodeGenerator.derive_skill_name(input)
      do_generate(input, skill_name, config, max_retries)
    end
  end

  @spec handle(String.t(), keyword()) :: :ok
  def handle(goal, opts \\ []) do
    case run(%{input: goal}) do
      {:ok, result, _branch} ->
        AlexClaw.Gateway.Router.send_message(result, opts)

      {:error, reason} ->
        Logger.warning("Coder failed: #{inspect(reason)}", skill: :coder)
        AlexClaw.Gateway.Router.send_message("Coder failed: #{inspect(reason)}", opts)
    end
  end

  defp do_generate(goal, skill_name, config, max_retries) do
    case generation_loop(goal, skill_name, max_retries, nil) do
      {:ok, result} ->
        if config["create_workflow"] do
          case create_skill_workflow(skill_name) do
            {:ok, workflow_info} ->
              {:ok, format_result(result, workflow_info), :on_workflow_created}

            {:error, _reason} ->
              {:ok, format_result(result, nil), :on_created}
          end
        else
          {:ok, format_result(result, nil), :on_created}
        end

      {:error, _} = err ->
        err
    end
  end

  defp generation_loop(_goal, _skill_name, 0, last_error) do
    {:error, {:generation_failed, last_error}}
  end

  defp generation_loop(goal, skill_name, retries_left, error_context) do
    case CodeGenerator.generate_step(goal, skill_name, "both", "auto", error_context) do
      {:ok, result} ->
        Logger.info("Coder: generated skill #{result.name}", skill: :coder)
        {:ok, result}

      {:error, reason, _code} ->
        Logger.warning("Coder: generation failed (#{retries_left - 1} retries left): #{inspect(reason)}", skill: :coder)
        hint = CodeGenerator.error_to_hint(reason)
        generation_loop(goal, skill_name, retries_left - 1, hint)
    end
  end

  defp create_skill_workflow(skill_name) do
    with {:ok, workflow} <- SkillAPI.create_workflow(__MODULE__, %{name: "Auto: #{skill_name}", enabled: false}),
         {:ok, _step1} <- SkillAPI.add_workflow_step(__MODULE__, workflow.id, %{name: skill_name, skill: skill_name, position: 1}),
         {:ok, _step2} <- SkillAPI.add_workflow_step(__MODULE__, workflow.id, %{name: "notify", skill: "telegram_notify", position: 2}) do
      {:ok, %{workflow_id: workflow.id, workflow_name: workflow.name}}
    end
  end

  defp format_result(result, nil) do
    """
    Skill *#{result.name}* generated and loaded.
    Permissions: #{inspect(result.permissions)}
    Routes: #{inspect(result.routes)}
    """
  end

  defp format_result(result, workflow_info) do
    """
    Skill *#{result.name}* generated and loaded.
    Permissions: #{inspect(result.permissions)}
    Routes: #{inspect(result.routes)}

    Workflow *#{workflow_info.workflow_name}* created (disabled).
    Enable it in Admin > Workflows or run with `/run #{workflow_info.workflow_id}`
    """
  end
end
