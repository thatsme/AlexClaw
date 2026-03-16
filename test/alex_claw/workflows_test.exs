defmodule AlexClaw.WorkflowsTest do
  use AlexClaw.DataCase, async: false

  alias AlexClaw.Workflows

  defp create_workflow(attrs \\ %{}) do
    default = %{name: "Test Workflow #{System.unique_integer([:positive])}", enabled: true}
    {:ok, wf} = Workflows.create_workflow(Map.merge(default, attrs))
    wf
  end

  describe "create_workflow/1" do
    test "creates with valid attrs" do
      {:ok, wf} = Workflows.create_workflow(%{name: "My Workflow"})
      assert wf.name == "My Workflow"
      assert wf.enabled == true
    end

    test "fails without name" do
      {:error, cs} = Workflows.create_workflow(%{})
      assert %{name: ["can't be blank"]} = errors_on(cs)
    end
  end

  describe "update_workflow/2" do
    test "updates attributes" do
      wf = create_workflow()
      {:ok, updated} = Workflows.update_workflow(wf, %{description: "updated desc"})
      assert updated.description == "updated desc"
    end
  end

  describe "delete_workflow/1" do
    test "removes workflow" do
      wf = create_workflow()
      {:ok, _} = Workflows.delete_workflow(wf)
      assert_raise Ecto.NoResultsError, fn -> Workflows.get_workflow!(wf.id) end
    end
  end

  describe "list_workflows/0" do
    test "returns all workflows ordered by name" do
      create_workflow(%{name: "Zebra"})
      create_workflow(%{name: "Alpha"})

      names = Workflows.list_workflows() |> Enum.map(& &1.name)
      assert "Alpha" in names
      assert "Zebra" in names
      assert Enum.find_index(names, &(&1 == "Alpha")) < Enum.find_index(names, &(&1 == "Zebra"))
    end
  end

  describe "steps" do
    test "add_step assigns auto-incrementing position" do
      wf = create_workflow()
      {:ok, s1} = Workflows.add_step(wf, %{name: "Step 1", skill: "api_request"})
      {:ok, s2} = Workflows.add_step(wf, %{name: "Step 2", skill: "llm_transform"})

      assert s1.position == 1
      assert s2.position == 2
    end

    test "update_step changes attributes" do
      wf = create_workflow()
      {:ok, step} = Workflows.add_step(wf, %{name: "Original", skill: "api_request"})
      {:ok, updated} = Workflows.update_step(step, %{name: "Renamed"})
      assert updated.name == "Renamed"
    end

    test "remove_step deletes step" do
      wf = create_workflow()
      {:ok, step} = Workflows.add_step(wf, %{name: "Temp", skill: "api_request"})
      {:ok, _} = Workflows.remove_step(step)

      loaded = Workflows.get_workflow!(wf.id)
      assert loaded.steps == []
    end

    test "reorder_steps updates positions" do
      wf = create_workflow()
      {:ok, s1} = Workflows.add_step(wf, %{name: "A", skill: "api_request"})
      {:ok, s2} = Workflows.add_step(wf, %{name: "B", skill: "llm_transform"})

      {:ok, _} = Workflows.reorder_steps(wf, [s2.id, s1.id])

      loaded = Workflows.get_workflow!(wf.id)
      positions = loaded.steps |> Enum.sort_by(& &1.position) |> Enum.map(& &1.name)
      assert positions == ["B", "A"]
    end
  end

  describe "runs" do
    test "create_run and update_run" do
      wf = create_workflow()
      {:ok, run} = Workflows.create_run(wf)
      assert run.status == "running"
      assert run.workflow_id == wf.id

      {:ok, updated} = Workflows.update_run(run, %{status: "completed", completed_at: DateTime.utc_now()})
      assert updated.status == "completed"
    end

    test "list_runs returns runs for the workflow" do
      wf = create_workflow()
      {:ok, r1} = Workflows.create_run(wf)
      {:ok, r2} = Workflows.create_run(wf)

      runs = Workflows.list_runs(wf.id)
      ids = Enum.map(runs, & &1.id)
      assert r1.id in ids
      assert r2.id in ids
      assert length(runs) == 2
    end

    test "clear_runs removes all runs for workflow" do
      wf = create_workflow()
      {:ok, _} = Workflows.create_run(wf)
      {:ok, _} = Workflows.create_run(wf)

      {count, _} = Workflows.clear_runs(wf.id)
      assert count == 2
      assert Workflows.list_runs(wf.id) == []
    end
  end

  describe "list_scheduled_workflows/0" do
    test "only returns enabled workflows with schedule" do
      create_workflow(%{name: "Scheduled", enabled: true, schedule: "0 7 * * *"})
      create_workflow(%{name: "Manual", enabled: true, schedule: nil})
      create_workflow(%{name: "Disabled", enabled: false, schedule: "0 7 * * *"})

      scheduled = Workflows.list_scheduled_workflows()
      names = Enum.map(scheduled, & &1.name)
      assert "Scheduled" in names
      refute "Manual" in names
      refute "Disabled" in names
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
