defmodule AlexClaw.WorkflowsAdversarialTest do
  use AlexClaw.DataCase, async: false

  alias AlexClaw.{Workflows, Resources}

  defp create_workflow(attrs \\ %{}) do
    default = %{name: "WF #{System.unique_integer([:positive])}", enabled: true}
    {:ok, wf} = Workflows.create_workflow(Map.merge(default, attrs))
    wf
  end

  describe "workflow name uniqueness" do
    test "duplicate name fails" do
      {:ok, _} = Workflows.create_workflow(%{name: "Unique Name"})
      {:error, cs} = Workflows.create_workflow(%{name: "Unique Name"})
      assert cs.valid? == false or match?(%{name: _}, errors_on(cs))
    end
  end

  describe "step ordering edge cases" do
    test "add_step to workflow with many existing steps" do
      wf = create_workflow()

      for i <- 1..20 do
        {:ok, step} = Workflows.add_step(wf, %{name: "Step #{i}", skill: "api_request"})
        assert step.position == i
      end

      loaded = Workflows.get_workflow!(wf.id)
      assert length(loaded.steps) == 20
      positions = Enum.map(loaded.steps, & &1.position)
      assert positions == Enum.to_list(1..20)
    end

    test "reorder_steps with duplicate IDs" do
      wf = create_workflow()
      {:ok, s1} = Workflows.add_step(wf, %{name: "A", skill: "api_request"})

      result = Workflows.reorder_steps(wf, [s1.id, s1.id])
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "reorder_steps with nonexistent step ID" do
      wf = create_workflow()
      {:ok, s1} = Workflows.add_step(wf, %{name: "A", skill: "api_request"})

      result = Workflows.reorder_steps(wf, [s1.id, 999_999])
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "remove_step then reorder remaining" do
      wf = create_workflow()
      {:ok, s1} = Workflows.add_step(wf, %{name: "A", skill: "api_request"})
      {:ok, s2} = Workflows.add_step(wf, %{name: "B", skill: "api_request"})
      {:ok, s3} = Workflows.add_step(wf, %{name: "C", skill: "api_request"})

      {:ok, _} = Workflows.remove_step(s2)
      {:ok, _} = Workflows.reorder_steps(wf, [s3.id, s1.id])

      loaded = Workflows.get_workflow!(wf.id)
      names = loaded.steps |> Enum.sort_by(& &1.position) |> Enum.map(& &1.name)
      assert names == ["C", "A"]
    end
  end

  describe "workflow-resource association" do
    test "assign same resource twice is idempotent or errors" do
      wf = create_workflow()
      {:ok, resource} = Resources.create_resource(%{name: "RSS #{System.unique_integer([:positive])}", type: "rss_feed"})

      {:ok, _} = Workflows.assign_resource(wf, resource.id, "input")
      result = Workflows.assign_resource(wf, resource.id, "input")
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "unassign resource that was never assigned returns zero deletes" do
      wf = create_workflow()
      {:ok, resource} = Resources.create_resource(%{name: "Orphan #{System.unique_integer([:positive])}", type: "api"})

      {count, _} = Workflows.unassign_resource(wf, resource.id)
      assert count == 0
    end

    test "delete resource cascades — removes from workflow" do
      wf = create_workflow()
      {:ok, resource} = Resources.create_resource(%{name: "Cascade #{System.unique_integer([:positive])}", type: "api"})
      {:ok, _} = Workflows.assign_resource(wf, resource.id, "input")

      {:ok, _} = Resources.delete_resource(resource)

      loaded = Workflows.get_workflow!(wf.id)
      assert loaded.resources == []
    end

    test "delete workflow cascades — removes steps and run history" do
      wf = create_workflow()
      {:ok, _} = Workflows.add_step(wf, %{name: "Step", skill: "api_request"})
      {:ok, _} = Workflows.create_run(wf)

      {:ok, _} = Workflows.delete_workflow(wf)

      assert_raise Ecto.NoResultsError, fn ->
        Workflows.get_workflow!(wf.id)
      end

      assert Workflows.list_runs(wf.id) == []
    end
  end

  describe "workflow run edge cases" do
    test "create_run on workflow with no steps" do
      wf = create_workflow()
      {:ok, run} = Workflows.create_run(wf)
      assert run.status == "running"
      assert run.workflow_id == wf.id
    end

    test "update_run with invalid status" do
      wf = create_workflow()
      {:ok, run} = Workflows.create_run(wf)

      {:error, cs} = Workflows.update_run(run, %{status: "invalid_status"})
      assert cs.valid? == false
    end

    test "clear_runs when no runs exist" do
      wf = create_workflow()
      {count, _} = Workflows.clear_runs(wf.id)
      assert count == 0
    end
  end

  describe "schedule edge cases" do
    test "workflow with invalid cron still saves (validation is at runtime)" do
      wf = create_workflow(%{schedule: "not a cron"})
      assert wf.schedule == "not a cron"
    end

    test "list_scheduled_workflows excludes nil schedule" do
      create_workflow(%{name: "No Schedule #{System.unique_integer([:positive])}", schedule: nil, enabled: true})

      scheduled = Workflows.list_scheduled_workflows()
      refute Enum.any?(scheduled, &is_nil(&1.schedule))
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
