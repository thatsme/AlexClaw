defmodule AlexClaw.Cluster.ManagerTest do
  @moduledoc """
  The cluster manager (0.4.0 S5c).

  Another node's request to run a workflow reaches this node's manager with a
  GenServer call, and the manager takes the SENDER from the call itself —
  the real node of the calling process — never from a name the sender
  passes. Over :rpc any node holding the cookie could claim a registered
  node's name; the registration check would then prove nothing.

  Admission, all before any run row exists:
  - the sender must be a registered node (registered in the admin UI);
  - step 1 must be the receive_from_workflow gate;
  - the gate's allowed_nodes must name the sender — an EMPTY list allows no
    one (no default: a workflow says who may trigger it);
  - the workflow must be enabled and unprotected.

  In these tests the sender is the node the test runs on (`node()`), calling
  its own manager.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Cluster.Manager
  alias AlexClaw.Workflows
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    Sandbox.mode(AlexClaw.Repo, {:shared, self()})
    # 0.3.54: a telegram_notify step is saved only when Telegram is configured.
    insert_setting("telegram.enabled", "true", type: "boolean", category: "telegram")
    AlexClaw.Config.set("telegram.bot_token", "test-token", type: "string", category: "telegram")

    sender = to_string(node())
    {:ok, _} = AlexClaw.Cluster.create_node(%{name: sender})
    %{sender: sender}
  end

  defp create_workflow(attrs \\ %{}) do
    default = %{name: "Test Workflow #{System.unique_integer([:positive])}", enabled: true}
    {:ok, wf} = Workflows.create_workflow(Map.merge(default, attrs))
    wf
  end

  defp gate(wf, allowed) do
    {:ok, _} =
      Workflows.add_step(wf, %{
        name: "Receive",
        skill: "receive_from_workflow",
        config: %{"allowed_nodes" => allowed}
      })
  end

  defp runs_of(wf), do: Workflows.list_runs(wf.id)

  describe "receive_workflow_data/2" do
    test "rejects a workflow that doesn't exist" do
      assert {:error, :workflow_not_found} =
               Manager.receive_workflow_data("nonexistent_workflow", "data")
    end

    test "rejects a disabled workflow", %{sender: sender} do
      wf = create_workflow(%{enabled: false})
      gate(wf, [sender])

      assert {:error, :workflow_not_found} = Manager.receive_workflow_data(wf.name, "data")
      assert runs_of(wf) == []
    end

    test "rejects a workflow without receive_from_workflow as step 1" do
      wf = create_workflow()
      {:ok, _} = Workflows.add_step(wf, %{name: "Notify", skill: "telegram_notify", config: %{}})

      assert {:error, :no_receive_gate} = Manager.receive_workflow_data(wf.name, "data")
      assert runs_of(wf) == []
    end

    test "rejects a workflow with receive_from_workflow not as step 1", %{sender: sender} do
      wf = create_workflow()
      {:ok, _} = Workflows.add_step(wf, %{name: "First", skill: "telegram_notify", config: %{}})
      gate(wf, [sender])

      assert {:error, :no_receive_gate} = Manager.receive_workflow_data(wf.name, "data")
      assert runs_of(wf) == []
    end

    test "an empty allowed_nodes allows no one (no default)" do
      wf = create_workflow()
      gate(wf, [])

      assert {:error, :node_not_allowed} = Manager.receive_workflow_data(wf.name, "data")
      assert runs_of(wf) == []
    end

    test "accepts from a registered sender the gate names", %{sender: sender} do
      wf = create_workflow()
      gate(wf, [sender])

      assert {:ok, :started} = Manager.receive_workflow_data(wf.name, "hello from remote")

      assert Enum.any?(1..50, fn _ -> runs_of(wf) != [] or (Process.sleep(20) && false) end),
             "no run was created"
    end

    test "accepts with additional steps after the gate", %{sender: sender} do
      wf = create_workflow()
      gate(wf, [sender])
      {:ok, _} = Workflows.add_step(wf, %{name: "Notify", skill: "telegram_notify", config: %{}})

      assert {:ok, :started} = Manager.receive_workflow_data(wf.name, %{"key" => "value"})
    end

    test "an unregistered sender is refused, even if the gate names it", %{sender: sender} do
      AlexClaw.Cluster.get_by_name(sender) |> AlexClaw.Cluster.delete_node()
      wf = create_workflow()
      gate(wf, [sender])

      assert {:error, :node_not_registered} = Manager.receive_workflow_data(wf.name, "data")
      assert runs_of(wf) == []
    end
  end

  describe "nodeup/nodedown handling" do
    test "nodeup does not register an unknown node" do
      name = "alexclaw@autotest#{System.unique_integer([:positive])}.local"
      send(Manager, {:nodeup, String.to_atom(name)})
      :sys.get_state(Manager)

      assert is_nil(AlexClaw.Cluster.get_by_name(name))
    end

    test "nodedown marks a registered node as disconnected" do
      {:ok, node} =
        AlexClaw.Cluster.create_node(%{name: "alexclaw@downtest.local", status: "connected"})

      send(Manager, {:nodedown, :"alexclaw@downtest.local"})
      :sys.get_state(Manager)

      updated = AlexClaw.Cluster.get_node!(node.id)
      assert updated.status == "disconnected"
    end
  end
end
