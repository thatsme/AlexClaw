defmodule AlexClaw.Cluster.ManagerTest do
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Cluster.Manager
  alias AlexClaw.Workflows

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(AlexClaw.Repo, {:shared, self()})
    :ok
  end

  defp create_workflow(attrs \\ %{}) do
    default = %{name: "Test Workflow #{System.unique_integer([:positive])}", enabled: true}
    {:ok, wf} = Workflows.create_workflow(Map.merge(default, attrs))
    wf
  end

  describe "receive_workflow_data/3" do
    test "rejects workflow that doesn't exist" do
      assert {:error, :workflow_not_found} =
               Manager.receive_workflow_data("nonexistent_workflow", "data", "alexclaw@test.local")
    end

    test "rejects disabled workflow" do
      wf = create_workflow(%{enabled: false})

      {:ok, _} =
        Workflows.add_step(wf, %{
          name: "Receive",
          skill: "receive_from_workflow",
          config: %{}
        })

      assert {:error, :workflow_not_found} =
               Manager.receive_workflow_data(wf.name, "data", "alexclaw@test.local")
    end

    test "rejects workflow without receive_from_workflow as step 1" do
      wf = create_workflow()

      {:ok, _} =
        Workflows.add_step(wf, %{
          name: "Notify",
          skill: "telegram_notify",
          config: %{}
        })

      assert {:error, :no_receive_gate} =
               Manager.receive_workflow_data(wf.name, "data", "alexclaw@test.local")
    end

    test "rejects workflow with receive_from_workflow not as step 1" do
      wf = create_workflow()

      {:ok, _} =
        Workflows.add_step(wf, %{
          name: "First",
          skill: "telegram_notify",
          config: %{}
        })

      {:ok, _} =
        Workflows.add_step(wf, %{
          name: "Receive",
          skill: "receive_from_workflow",
          config: %{}
        })

      assert {:error, :no_receive_gate} =
               Manager.receive_workflow_data(wf.name, "data", "alexclaw@test.local")
    end

    test "accepts workflow with receive_from_workflow as step 1" do
      wf = create_workflow()

      {:ok, _} =
        Workflows.add_step(wf, %{
          name: "Receive",
          skill: "receive_from_workflow",
          config: %{}
        })

      assert {:ok, :started} =
               Manager.receive_workflow_data(wf.name, "hello from remote", "alexclaw@test.local")

      # Give the async task a moment to execute
      Process.sleep(500)

      # Verify a run was created
      runs = Workflows.list_runs(wf.id)
      assert length(runs) >= 1
    end

    test "accepts workflow with receive_from_workflow + additional steps" do
      wf = create_workflow()

      {:ok, _} =
        Workflows.add_step(wf, %{
          name: "Receive",
          skill: "receive_from_workflow",
          config: %{}
        })

      {:ok, _} =
        Workflows.add_step(wf, %{
          name: "Notify",
          skill: "telegram_notify",
          config: %{}
        })

      assert {:ok, :started} =
               Manager.receive_workflow_data(wf.name, %{"key" => "value"}, "alexclaw@node1.local")
    end
  end

  describe "nodeup/nodedown handling" do
    test "nodeup auto-registers unknown node" do
      name = "alexclaw@autotest#{System.unique_integer([:positive])}.local"
      send(Manager, {:nodeup, String.to_atom(name)})
      Process.sleep(200)

      node = AlexClaw.Cluster.get_by_name(name)
      assert node
      assert node.status == "connected"
    end

    test "nodedown marks node as disconnected" do
      {:ok, node} =
        AlexClaw.Cluster.create_node(%{
          name: "alexclaw@downtest.local",
          status: "connected"
        })

      send(Manager, {:nodedown, :"alexclaw@downtest.local"})
      Process.sleep(200)

      updated = AlexClaw.Cluster.get_node!(node.id)
      assert updated.status == "disconnected"
    end
  end
end
