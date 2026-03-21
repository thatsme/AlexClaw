defmodule AlexClaw.Skills.ShellWorkflowTest do
  use AlexClaw.DataCase, async: false

  alias AlexClaw.Workflows
  alias AlexClaw.Workflows.Executor

  describe "shell skill in workflow" do
    setup do
      AlexClaw.Config.set("shell.enabled", "true", type: "boolean", category: "shell")
      :ok
    end

    test "executes OS memory check via workflow" do
      {:ok, workflow} =
        Workflows.create_workflow(%{
          name: "OS Memory Check",
          description: "Container memory introspection via shell skill",
          enabled: true
        })

      {:ok, _step} =
        Workflows.add_step(workflow, %{
          name: "check_memory",
          skill: "shell",
          position: 1,
          config: %{"command" => "free -m"}
        })

      {:ok, run} = Executor.run(workflow.id)

      assert run.status == "completed"
      assert run.result["output"] =~ "Mem:"
      assert run.result["output"] =~ "Exit: 0"
    end

    test "executes disk usage check via workflow" do
      {:ok, workflow} =
        Workflows.create_workflow(%{
          name: "Disk Usage Check",
          description: "Container disk introspection via shell skill",
          enabled: true
        })

      {:ok, _step} =
        Workflows.add_step(workflow, %{
          name: "check_disk",
          skill: "shell",
          position: 1,
          config: %{"command" => "df -h"}
        })

      {:ok, run} = Executor.run(workflow.id)

      assert run.status == "completed"
      assert run.result["output"] =~ "Filesystem"
      assert run.result["output"] =~ "Exit: 0"
    end

    test "non-whitelisted command fails the workflow step" do
      {:ok, workflow} =
        Workflows.create_workflow(%{
          name: "Bad Command Test",
          enabled: true
        })

      {:ok, _step} =
        Workflows.add_step(workflow, %{
          name: "bad_cmd",
          skill: "shell",
          position: 1,
          config: %{"command" => "rm -rf /"}
        })

      {:error, run} = Executor.run(workflow.id)

      assert run.status == "failed"
    end
  end
end
