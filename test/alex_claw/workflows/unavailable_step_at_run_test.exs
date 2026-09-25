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

  # A failed run returns {:error, %WorkflowRun{}} (executor.ex:30-32). The
  # error being {:unavailable, reason} — and not a failure from Coder itself —
  # is what shows the skill never ran: had it run, the error would be Coder's
  # own (in the test stack, its missing model).
  test "the step fails as unavailable, with the skill's reason; the skill never runs", %{wf: wf} do
    assert {:error, run} = Executor.run(wf.id)

    assert run.status == "failed"
    assert inspect(run) =~ ":unavailable", "the step did not fail as unavailable: #{inspect(run)}"

    assert inspect(run) =~ ~r/not a workflow step|Forge/i,
           "the reason is not reported: #{inspect(run)}"
  end
end
