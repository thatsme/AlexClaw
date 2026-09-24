defmodule AlexClaw.Skills.Coder do
  @moduledoc """
  Autonomous code generation skill. Uses the local LLM to generate
  dynamic skills from natural language goals, then loads them via SkillAPI.
  Delegates generation logic to `AlexClaw.Skills.CodeGenerator`.
  """
  @behaviour AlexClaw.Skill
  require Logger

  alias AlexClaw.Auth.Gate
  alias AlexClaw.Gateway.Router
  alias AlexClaw.Skills.{CodeGenerator, ForgeGuard, SkillAPI}

  @impl true
  @spec description() :: String.t()
  def description, do: "Generate dynamic skills from natural language goals using local LLM"

  @impl true
  @spec routes() :: [atom()]
  def routes, do: [:on_created, :on_workflow_created, :on_partial, :on_error]

  # :on_partial — the skill loaded but the workflow asked for was not created.
  @impl true
  @spec error_routes() :: [atom()]
  def error_routes, do: [:on_partial, :on_error]

  @impl true
  @spec permissions() :: :all
  def permissions, do: :all

  @impl true
  @spec step_fields() :: [atom()]
  def step_fields, do: [:config]

  @impl true
  @spec config_hint() :: String.t()
  def config_hint,
    do:
      ~s|{"goal": "describe what the skill should do", "create_workflow": false, "max_retries": 3}|

  @impl true
  @spec config_scaffold() :: map()
  def config_scaffold, do: %{"goal" => "", "create_workflow" => false, "max_retries" => 3}

  @impl true
  @spec config_schema() :: AlexClaw.Skill.config_schema()
  def config_schema do
    %{
      "goal" => %{type: :string, required: false},
      "create_workflow" => %{type: :boolean, required: false},
      "max_retries" => %{type: :integer, required: false}
    }
  end

  @impl true
  @spec config_presets() :: %{String.t() => map()}
  def config_presets do
    %{
      "BEAM stats" => %{
        "goal" => "a skill that returns the current BEAM process count and memory usage"
      },
      "With workflow" => %{"goal" => "a skill that checks disk space", "create_workflow" => true}
    }
  end

  @impl true
  @spec config_help() :: String.t()
  def config_help,
    do:
      "goal: natural language description of the skill to generate. create_workflow: if true, creates a workflow with the generated skill. max_retries: number of generation attempts (default 5, at most 5)."

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
        Router.send_message(result, opts)

      {:error, reason} ->
        Logger.warning("Coder failed: #{inspect(reason)}", skill: :coder)
        Router.send_message("Coder failed: #{inspect(reason)}", opts)
    end
  end

  # One generation at a time, a bounded number of attempts, and a time budget
  # across them all: see ForgeGuard. A second request is refused, not queued.
  defp do_generate(goal, skill_name, config, max_retries) do
    job = %{goal: goal, skill_name: skill_name, deadline: ForgeGuard.deadline()}

    case ForgeGuard.run(fn -> generation_loop(job, ForgeGuard.attempts(max_retries), nil) end) do
      {:ok, result} -> generated(result, skill_name, config["create_workflow"])
      {:needs_approval, violations} -> request_approval(skill_name, violations)
      {:error, _reason} = err -> err
    end
  end

  # The file is already staged in pending/. It loads only if a code is verified.
  defp request_approval(skill_name, violations) do
    listed = Enum.map_join(violations, ", ", & &1)

    %{type: :skill_load, file_path: "#{skill_name}.ex", origin: :generated}
    |> Gate.request("Generated skill #{skill_name} needs: #{listed}")
    |> approval_result(skill_name, listed)
  end

  defp approval_result(:challenged, skill_name, listed) do
    {:ok,
     """
     Generated skill *#{skill_name}* is waiting for approval.

     It calls outside the contained set: #{listed}
     A 2FA code has been requested — approve it to load the skill.
     """, :on_created}
  end

  defp approval_result({:locked, minutes}, skill_name, listed) do
    {:error,
     {:needs_2fa,
      "Generated skill #{skill_name} calls outside the contained set (#{listed}), " <>
        "and code entry is locked after too many wrong codes, so no approval was requested. " <>
        "It is staged in pending/; try again in #{minutes} min."}}
  end

  defp approval_result(:no_2fa, skill_name, listed) do
    {:error,
     {:needs_2fa,
      "Generated skill #{skill_name} calls outside the contained set (#{listed}) " <>
        "and 2FA is not configured, so it was not loaded. It is staged in pending/. " <>
        "Enable 2FA with /setup 2fa."}}
  end

  defp generated(result, _skill_name, nil), do: {:ok, format_result(result, nil), :on_created}
  defp generated(result, _skill_name, false), do: {:ok, format_result(result, nil), :on_created}

  defp generated(result, skill_name, _create_workflow) do
    case create_skill_workflow(skill_name) do
      {:ok, workflow_info} ->
        {:ok, format_result(result, workflow_info), :on_workflow_created}

      {:error, reason} ->
        Logger.warning("Coder: workflow for #{skill_name} not created: #{inspect(reason)}",
          skill: :coder
        )

        {:ok, partial_result(result, skill_name, reason), :on_partial}
    end
  end

  # The last failure is carried structurally, with its code, not just as a hint
  # string: a retry repairs that code, and when the model never gets inside the
  # containment envelope the caller needs the violations to ask for a code.
  defp generation_loop(job, attempts_left, last) when attempts_left > 0 do
    if ForgeGuard.expired?(job.deadline),
      do: gave_up(last, {:time_budget_spent, ForgeGuard.budget_seconds()}),
      else: job |> step(last) |> stepped(job, attempts_left)
  end

  defp generation_loop(_job, 0, last), do: gave_up(last, nil)

  defp step(job, nil),
    do: CodeGenerator.generate_step(job.goal, job.skill_name, "both", "auto", nil)

  defp step(job, last),
    do: CodeGenerator.retry_step(job.goal, job.skill_name, "both", "auto", last)

  defp stepped({:ok, result}, _job, _attempts_left) do
    Logger.info("Coder: generated skill #{result.name}", skill: :coder)
    {:ok, result}
  end

  defp stepped({:error, reason, code}, job, attempts_left) do
    Logger.warning(
      "Coder: generation failed (#{attempts_left - 1} attempts left): #{inspect(reason)}",
      skill: :coder
    )

    generation_loop(job, attempts_left - 1, {reason, code})
  end

  defp gave_up({{:not_contained, violations}, _code}, _why), do: {:needs_approval, violations}
  defp gave_up({reason, _code}, nil), do: {:error, {:generation_failed, reason}}
  defp gave_up(_last, why), do: {:error, {:generation_failed, why}}

  defp create_skill_workflow(skill_name) do
    with {:ok, workflow} <-
           SkillAPI.create_workflow(__MODULE__, %{name: "Auto: #{skill_name}", enabled: false}),
         {:ok, _step1} <-
           SkillAPI.add_workflow_step(__MODULE__, workflow.id, %{
             name: skill_name,
             skill: skill_name,
             position: 1
           }),
         {:ok, _step2} <-
           SkillAPI.add_workflow_step(__MODULE__, workflow.id, %{
             name: "notify",
             skill: "telegram_notify",
             position: 2
           }) do
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

  # The skill loaded; the workflow asked for was not created, and the message says why.
  defp partial_result(result, skill_name, reason) do
    format_result(result, nil) <>
      "\nWorkflow *Auto: #{skill_name}* was not created: #{why(reason)}\n"
  end

  defp why(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  defp why(reason), do: inspect(reason)
end
