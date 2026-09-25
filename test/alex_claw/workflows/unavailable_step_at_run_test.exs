defmodule AlexClaw.Workflows.UnavailableStepAtRunTest do
  @moduledoc """
  A skill that is not available as a workflow step does not run as one, even
  in a workflow saved before it became unavailable (0.4.0 S5b).

  Since S5b Coder is not a workflow step (`available?/0` is false, and saving
  such a step is refused with its `unavailable_reason/0`). But a workflow
  saved earlier can still hold a Coder step, and the executor did not check
  availability when running — so the restriction would apply only to
  workflows created from now on. The executor now checks it at run time too:
  the step fails with the skill's reason, and the skill does not run.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Workflows
  alias AlexClaw.Workflows.{Executor, WorkflowStep}
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    Sandbox.mode(AlexClaw.Repo, {:shared, self()})

    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "legacy-coder-#{System.unique_integer([:positive])}",
        enabled: true
      })

    # As a workflow saved before 0.4.0 would hold it: inserted directly, past
    # the save-time check that now refuses it.
    Repo.insert!(%WorkflowStep{
      workflow_id: wf.id,
      name: "Generate",
      skill: "coder",
      position: 1,
      config: %{"goal" => "a skill that says hello"}
    })

    %{wf: wf}
  end

  test "the step fails with the skill's reason, and the run says so", %{wf: wf} do
    assert {:ok, run} = Executor.run(wf.id)

    assert run.status == "failed"

    assert inspect(run) =~ ~r/not a workflow step|Forge/i,
           "the reason is not reported: #{inspect(run)}"
  end

  test "Coder itself never runs: no skill is generated", %{wf: wf} do
    skills_dir = Application.get_env(:alex_claw, :skills_dir)
    before = if File.dir?(skills_dir), do: File.ls!(skills_dir), else: []

    Executor.run(wf.id)

    after_run = if File.dir?(skills_dir), do: File.ls!(skills_dir), else: []
    assert Enum.sort(after_run) == Enum.sort(before)
  end
end
