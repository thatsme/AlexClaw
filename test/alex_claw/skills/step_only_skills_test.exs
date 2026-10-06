defmodule AlexClaw.Skills.StepOnlySkillsTest do
  @moduledoc """
  A step-only skill runs only as a saved workflow step of its own
  (reports/SQLREAD_ATTACKER_REVIEW.md H2). `sql_query` is one: its query is
  fixed and checked by an elevated save (the dry run), so nothing else may
  hand it a config.

  - Cross-skill invocation (`:run_skill`, whoever performs it — a skill
    through SkillAPI, the reasoning loop, the system) is refused and audited,
    and the skill does not run.
  - A step may not name it as its fallback (`fallback_skill`), which would
    run it with another step's config: refused at save, and before every run
    (the executor checks a step's config again at run time).
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.AuditLog
  alias AlexClaw.{ControlPlane, Workflows}
  alias AlexClaw.ControlPlane.Context
  alias AlexClaw.Skills.Invoke
  alias AlexClaw.Workflows.StepConfig

  @args %{
    config: %{
      "connection" => "never_defined",
      "query" => "SELECT 1 AS n",
      "timeout_ms" => 1_000
    }
  }

  defp sql_runs, do: Enum.count(AuditLog.recent(limit: 200), &(&1.permission == "sql.run"))

  test "sql_query is a step-only skill" do
    assert "sql_query" in Invoke.step_only_skills()
  end

  test "a cross-skill invocation is refused, audited, and the skill does not run" do
    before = sql_runs()

    assert {:error, :step_only_skill} = Invoke.run(__MODULE__, "sql_query", @args)

    assert sql_runs() == before
    assert Enum.any?(AuditLog.recent(limit: 20), &(&1.reason =~ "step-only skill 'sql_query'"))
  end

  for {label, context} <- [
        {"a skill (SkillAPI)", quote(do: Context.skill("SomeDynamicSkill"))},
        {"the system (reasoning loop)", quote(do: Context.system("reasoning"))}
      ] do
    test "run_skill performed by #{label} is refused" do
      before = sql_runs()
      params = %{caller: __MODULE__, skill: "sql_query", args: @args}

      assert {:error, :step_only_skill} =
               ControlPlane.perform(:run_skill, params, unquote(context))

      assert sql_runs() == before
    end
  end

  test "a step naming it as its fallback is refused at save" do
    {:ok, wf} =
      Workflows.create_workflow(%{name: "step-only #{System.unique_integer()}", enabled: true})

    assert {:error, changeset} =
             Workflows.add_step(wf, %{
               name: "Fetch",
               skill: "api_request",
               config: %{"url" => "https://api.example.com/x", "fallback_skill" => "sql_query"}
             })

    assert inspect(changeset.errors) =~ "fallback_skill"
  end

  test "a step naming it as its fallback is refused before it runs" do
    config = %{"url" => "https://api.example.com/x", "fallback_skill" => "sql_query"}

    assert {:error, [reason]} =
             StepConfig.validate(AlexClaw.Skills.ApiRequest, config, runtime: true)

    assert reason =~ "fallback_skill"
  end
end
