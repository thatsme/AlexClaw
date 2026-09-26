defmodule AlexClaw.Workflows.PrivilegedFallbackTest do
  @moduledoc """
  A privileged skill named as a step's fallback (`fallback_skill`, run when
  the step's circuit is open) counts as a privileged step: a run of such a
  workflow is refused up front outside the admin UI, naming it, like a step
  whose own skill is privileged (architect's review of SECURITY.md; S10
  review B). Before, the up-front check read `step.skill` only, and the
  fallback was refused mid-run, when it would have run.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  import Ecto.Query, only: [from: 2]

  alias AlexClaw.{ControlPlane, Workflows}
  alias AlexClaw.ControlPlane.Context
  alias AlexClaw.Workflows.{Launch, WorkflowRun}
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    Sandbox.mode(AlexClaw.Repo, {:shared, self()})
    AlexClaw.Config.set("shell.enabled", "true", type: "boolean", category: "shell")

    {:ok, wf} =
      Workflows.create_workflow(%{name: "fallback #{System.unique_integer()}", enabled: true})

    {:ok, _step} =
      Workflows.add_step(wf, %{
        name: "Fetch",
        skill: "api_request",
        config: %{"url" => "https://api.example.com/x", "fallback_skill" => "shell"}
      })

    {:ok, wf} = Workflows.get_workflow(wf.id)
    %{wf: wf}
  end

  test "a privileged fallback is named among the workflow's privileged steps", %{wf: wf} do
    assert Launch.privileged_steps(wf) == ["shell"]
  end

  test "a run of it from MCP is refused before it starts, naming the fallback", %{wf: wf} do
    assert {:error, {:privileged_steps, ["shell"]}} =
             ControlPlane.perform(:run_workflow, %{workflow_id: wf.id}, Context.mcp("probe"))

    AlexClaw.TaskDrain.drain()
    refute Repo.exists?(from(r in WorkflowRun, where: r.workflow_id == ^wf.id))
  end

  test "the admin UI asks for a code to run it", %{wf: wf} do
    assert Launch.needs_code?(wf)
  end
end
