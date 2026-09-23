defmodule AlexClaw.Workflows.ManagementTruthTest do
  @moduledoc """
  Managing workflows tells the truth (reports/WORKFLOW_LIFECYCLE_REVIEW.md,
  friction items 9, 11, 19, 20).

  - Cloning the same workflow twice raised a MatchError on the unique name;
    now the second clone is "<name> (copy 2)", the third "(copy 3)".
  - A clone lost `requires_2fa` (in metadata) and `node`; a clone is a copy,
    including its protection. (Schedule stays nil and enabled false, as
    before: a clone does not start running on its own.)
  - A step saved with the provider select's default stored "auto", which
    then overrode the workflow's default provider. `"auto"` or no model on a
    step means "use the workflow's provider".
  - "Run" on a disabled workflow said "triggered" while nothing ran:
    `Launch.start/1` (it takes the workflow) now refuses a disabled workflow with
    `{:error, :workflow_disabled}` before starting anything.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Workflows
  alias AlexClaw.Workflows.{Executor, Launch}
  alias Ecto.Adapters.SQL.Sandbox

  defp workflow(attrs \\ %{}) do
    base = %{name: "Mgmt #{System.unique_integer([:positive])}", enabled: true}
    {:ok, wf} = Workflows.create_workflow(Map.merge(base, attrs))
    wf
  end

  describe "cloning" do
    test "the same workflow can be cloned more than once" do
      wf = workflow()

      assert {:ok, first} = Workflows.duplicate_workflow(wf)
      assert {:ok, second} = Workflows.duplicate_workflow(wf)
      assert {:ok, third} = Workflows.duplicate_workflow(wf)

      assert first.name == "#{wf.name} (copy)"
      assert second.name == "#{wf.name} (copy 2)"
      assert third.name == "#{wf.name} (copy 3)"
    end

    test "a clone keeps requires_2fa and node, and does not run on its own" do
      wf =
        workflow(%{
          metadata: %{"requires_2fa" => true},
          node: "alexclaw@node1.local",
          schedule: "0 6 * * *"
        })

      assert {:ok, copy} = Workflows.duplicate_workflow(wf)

      assert copy.metadata["requires_2fa"] == true
      assert copy.node == "alexclaw@node1.local"
      assert copy.schedule == nil
      assert copy.enabled == false
    end
  end

  describe "the step's provider" do
    test "\"auto\" or no model means the workflow's provider" do
      wf = %{default_provider: "workflow-provider"}

      assert Executor.provider_for(%{llm_model: "auto"}, wf) == "workflow-provider"
      assert Executor.provider_for(%{llm_model: nil}, wf) == "workflow-provider"
      assert Executor.provider_for(%{llm_model: ""}, wf) == "workflow-provider"
    end

    test "a model chosen on the step wins" do
      assert Executor.provider_for(%{llm_model: "step-model"}, %{default_provider: "wf"}) ==
               "step-model"
    end
  end

  describe "running a disabled workflow" do
    test "is refused before anything starts, and says so" do
      wf = workflow(%{enabled: false})

      assert {:error, :workflow_disabled} = Launch.start(wf)
      assert Workflows.list_runs(wf.id) == []
    end

    test "an enabled workflow still starts" do
      Sandbox.mode(AlexClaw.Repo, {:shared, self()})
      wf = workflow()

      assert :started = Launch.start(wf)

      # Wait for the run to finish, so it does not outlive the test's sandbox.
      assert Enum.any?(1..100, fn _ ->
               match?([%{status: s} | _] when s != "running", Workflows.list_runs(wf.id)) or
                 (Process.sleep(20) && false)
             end)
    end
  end
end
