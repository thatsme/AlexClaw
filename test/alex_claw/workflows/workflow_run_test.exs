defmodule AlexClaw.Workflows.WorkflowRunTest do
  use AlexClaw.DataCase, async: true
  @moduletag :integration

  alias AlexClaw.Workflows.WorkflowRun

  describe "changeset/2" do
    test "valid with required fields" do
      cs = WorkflowRun.changeset(%WorkflowRun{}, %{
        status: "running",
        started_at: DateTime.utc_now()
      })

      assert cs.valid?
    end

    test "valid with all fields" do
      now = DateTime.utc_now()

      cs = WorkflowRun.changeset(%WorkflowRun{}, %{
        status: "completed",
        started_at: now,
        completed_at: now,
        result: %{"output" => "done"},
        error: nil,
        step_results: %{"1" => %{"name" => "step1"}}
      })

      assert cs.valid?
    end

    test "status defaults to running" do
      cs = WorkflowRun.changeset(%WorkflowRun{}, %{started_at: DateTime.utc_now()})
      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :status) == "running"
    end

    test "invalid without started_at" do
      cs = WorkflowRun.changeset(%WorkflowRun{}, %{status: "running"})
      refute cs.valid?
      assert "can't be blank" in errors_on_field(cs, :started_at)
    end

    test "validates status inclusion" do
      for status <- ~w(running completed failed cancelled) do
        cs = WorkflowRun.changeset(%WorkflowRun{}, %{
          status: status, started_at: DateTime.utc_now()
        })
        assert cs.valid?, "Expected status '#{status}' to be valid"
      end
    end

    test "rejects invalid status" do
      cs = WorkflowRun.changeset(%WorkflowRun{}, %{
        status: "paused", started_at: DateTime.utc_now()
      })
      refute cs.valid?
      assert errors_on_field(cs, :status) != []
    end

    test "defaults result to empty map" do
      cs = WorkflowRun.changeset(%WorkflowRun{}, %{
        status: "running", started_at: DateTime.utc_now()
      })
      assert Ecto.Changeset.get_field(cs, :result) == %{}
    end

    test "defaults step_results to empty map" do
      cs = WorkflowRun.changeset(%WorkflowRun{}, %{
        status: "running", started_at: DateTime.utc_now()
      })
      assert Ecto.Changeset.get_field(cs, :step_results) == %{}
    end
  end

  defp errors_on_field(changeset, field) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Map.get(field, [])
  end
end
