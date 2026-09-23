defmodule AlexClaw.MCP.WorkflowInputTest do
  @moduledoc """
  F8: a workflow run over MCP with an `input` must hand that input to step 1.
  It used to go through the cluster entry point, which delivers input only to
  a receive_from_workflow step, so an ordinary workflow never saw it.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.MCP.Server
  alias AlexClaw.Workflows
  alias AlexClawTest.ReasoningLoopHelper
  alias Anubis.Server.Frame
  alias Ecto.Adapters.SQL.Sandbox

  @workflow "f8_echo"

  setup do
    Sandbox.mode(AlexClaw.Repo, {:shared, self()})
    echo = ReasoningLoopHelper.register_echo_skill()
    on_exit(fn -> ReasoningLoopHelper.unregister_echo_skill(echo) end)

    {:ok, workflow} = Workflows.create_workflow(%{name: @workflow, enabled: true})
    {:ok, _} = Workflows.add_step(workflow, %{name: "echo", skill: echo, position: 1})

    %{workflow: workflow}
  end

  test "the tool's input reaches step 1", %{workflow: workflow} do
    result =
      Server.handle_tool_call("workflow:#{@workflow}", %{"input" => "hello f8"}, Frame.new())

    refute match?({:error, _, _}, result), "the tool call was refused: #{inspect(result)}"

    run = finished_run(workflow.id)
    assert run.status == "completed", "run #{run.status}: #{inspect(run.error)}"
    assert inspect(run.step_results) =~ "echoed: hello f8"
  end

  defp finished_run(workflow_id) do
    finished? = fn ->
      match?(
        [%{status: status} | _] when status in ["completed", "failed"],
        Workflows.list_runs(workflow_id)
      )
    end

    assert Enum.any?(1..100, fn _ -> finished?.() or (Process.sleep(50) && false) end),
           "the run never finished"

    hd(Workflows.list_runs(workflow_id))
  end
end
