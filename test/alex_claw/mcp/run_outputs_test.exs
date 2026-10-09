defmodule AlexClaw.MCP.RunOutputsTest do
  @moduledoc """
  An MCP client reads run metadata, never a run's output: the resources
  `alexclaw://runs/list` and `alexclaw://runs/{id}` give a run's status,
  timing, node, its steps' names, skills and outcomes, and the kind of a
  failure — never `result`, `step_results` or an error's text, which can
  quote the data a step read (a `sql_query` step's rows, a database's
  message). The only output an MCP client receives is the answer to a run it
  started itself, through the workflow tool.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.MCP.ResourceProvider
  alias AlexClaw.Workflows
  alias Anubis.Server.{Frame, Response}

  @row "row-value-7781"
  @message "relation private-value-5524 does not exist"

  setup do
    {:ok, wf} = Workflows.create_workflow(%{name: "mcp runs #{System.unique_integer()}"})
    {:ok, run} = Workflows.create_run(wf, %{node: "node@test"})

    {:ok, run} =
      Workflows.update_run(run, %{
        status: "failed",
        completed_at: DateTime.utc_now(),
        result: %{"output" => %{"rows" => [%{"name" => @row}]}},
        error: "step 'Send': {:sql_error, \"42P01\", #{inspect(@message)}}",
        step_results: %{
          "1" => %{
            "name" => "Read",
            "skill" => "sql_query",
            "branch" => "on_success",
            "output" => %{"rows" => [%{"name" => @row}], "row_count" => 1}
          },
          "2" => %{
            "name" => "Send",
            "skill" => "sql_query",
            "error" => "{:sql_error, \"42P01\", #{inspect(@message)}}"
          }
        }
      })

    %{run: run}
  end

  defp read(uri) do
    {:reply, %Response{} = resp, _frame} = ResourceProvider.read(uri, Frame.new())
    {resp.contents["text"], Jason.decode!(resp.contents["text"])}
  end

  test "a run read by id is metadata only", %{run: run} do
    {text, data} = read("alexclaw://runs/#{run.id}")

    refute text =~ @row, "a step's output reached the MCP client"
    refute text =~ "private-value-5524", "an error's text reached the MCP client"
    refute Map.has_key?(data, "result")
    refute Map.has_key?(data, "step_results")

    assert data["status"] == "failed"
    assert data["node"] == "node@test"
    assert data["started_at"] && data["completed_at"]
    assert data["error_kind"] == "sql_error"

    assert [
             %{
               "position" => 1,
               "name" => "Read",
               "skill" => "sql_query",
               "outcome" => "on_success"
             },
             %{
               "position" => 2,
               "name" => "Send",
               "skill" => "sql_query",
               "outcome" => "error",
               "error_kind" => "sql_error"
             }
           ] = data["steps"]
  end

  test "the list of runs is metadata only", %{run: run} do
    {text, data} = read("alexclaw://runs/list")

    refute text =~ @row
    refute text =~ "private-value-5524"
    assert listed = Enum.find(data, &(&1["id"] == run.id))
    refute Map.has_key?(listed, "result")
    refute Map.has_key?(listed, "step_results")
    assert listed["error_kind"] == "sql_error"
  end

  test "the kind of a failure is its tag, an atom or an exception's name, never its text" do
    for {error, kind} <- [
          {"step 'A': {:connection_down, \"tcp connect: secret-host\"}", "connection_down"},
          {"step 'A': :timeout", "timeout"},
          {"step 'A': %Req.TransportError{reason: :econnrefused}", "Req.TransportError"},
          {"step 'A': \"a message quoting secret-value\"", "error"}
        ] do
      assert ResourceProvider.error_kind(error) == kind
    end

    assert ResourceProvider.error_kind(nil) == nil
  end
end
