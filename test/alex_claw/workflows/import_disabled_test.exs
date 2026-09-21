defmodule AlexClaw.Workflows.ImportDisabledTest do
  @moduledoc """
  An imported workflow arrives disabled, whatever the file says, and nothing
  of it is scheduled: enabling it is a separate, gated action.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Workflows

  defp file(attrs) do
    %{
      "version" => 1,
      "workflow" =>
        Map.merge(%{"name" => "imported-#{System.unique_integer([:positive])}"}, attrs),
      "steps" => [%{"position" => 1, "name" => "fetch", "skill" => "web_fetch", "config" => %{}}]
    }
  end

  test "a file saying enabled, with a schedule, imports disabled and schedules nothing" do
    {:ok, workflow, _warnings} =
      Workflows.import_workflow(file(%{"enabled" => true, "schedule" => "*/5 * * * *"}))

    refute workflow.enabled
    assert workflow.schedule == "*/5 * * * *", "the schedule is kept, for when it is enabled"
    # What SchedulerSync registers with Quantum: an imported workflow is not in it.
    refute Enum.any?(Workflows.list_scheduled_workflows(), &(&1.id == workflow.id))
  end

  test "a file without enabled, or saying false, imports disabled too" do
    for attrs <- [%{}, %{"enabled" => false}, %{"enabled" => nil}] do
      {:ok, workflow, _} = Workflows.import_workflow(file(attrs))
      refute workflow.enabled
    end
  end
end
