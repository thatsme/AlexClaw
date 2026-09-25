defmodule AlexClaw.Skills.ReceiveFromWorkflowTest do
  @moduledoc """
  The receive_from_workflow gate (0.4.0 S5c).

  A workflow whose step 1 is this gate exists to receive data from other
  nodes — the ones its `allowed_nodes` names. So the gate passes a run only
  when an allowed node sent it:
  - an absent or EMPTY `allowed_nodes` allows no one (no default: a workflow
    says who may trigger it) — in 0.3.x it allowed anyone;
  - a run with no source node (started on this node rather than by another)
    is refused: there is no sender to allow;
  - the cluster admission check has already refused an unregistered or
    unlisted sender before any run (cluster_door_test.exs, manager_test.exs);
    this is the same rule, at run time.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  alias AlexClaw.Skills.ReceiveFromWorkflow

  @node "alexclaw@node1.local"

  defp from(node, input),
    do: %{input: input, config: %{"allowed_nodes" => [@node], "_source_node" => node}}

  describe "run/1" do
    test "passes through input from an allowed node" do
      assert {:ok, "hello", :on_success} = ReceiveFromWorkflow.run(from(@node, "hello"))
    end

    test "preserves complex input data" do
      input = %{"results" => [1, 2, 3], "metadata" => %{"source" => "test"}}
      assert {:ok, ^input, :on_success} = ReceiveFromWorkflow.run(from(@node, input))
    end

    test "rejects nil input" do
      assert {:error, :no_input_received} = ReceiveFromWorkflow.run(from(@node, nil))
    end

    test "rejects missing input key" do
      assert {:error, :no_input_received} =
               ReceiveFromWorkflow.run(%{
                 config: %{"allowed_nodes" => [@node], "_source_node" => @node}
               })
    end

    test "an empty allowed_nodes allows no one" do
      assert {:error, _} =
               ReceiveFromWorkflow.run(%{
                 input: "data",
                 config: %{"allowed_nodes" => [], "_source_node" => @node}
               })
    end

    test "an absent allowed_nodes allows no one" do
      assert {:error, _} =
               ReceiveFromWorkflow.run(%{input: "data", config: %{"_source_node" => @node}})
    end

    test "a run with no source node is refused, even with a list" do
      assert {:error, _} =
               ReceiveFromWorkflow.run(%{input: "data", config: %{"allowed_nodes" => [@node]}})
    end

    test "accepts a node in allowed_nodes" do
      assert {:ok, "data", :on_success} =
               ReceiveFromWorkflow.run(%{
                 input: "data",
                 config: %{
                   "allowed_nodes" => ["alexclaw@node1.local", "alexclaw@node2.local"],
                   "_source_node" => "alexclaw@node1.local"
                 }
               })
    end

    test "rejects a node not in allowed_nodes" do
      assert {:error, {:unauthorized_node, "alexclaw@rogue.local"}} =
               ReceiveFromWorkflow.run(%{
                 input: "data",
                 config: %{"allowed_nodes" => [@node], "_source_node" => "alexclaw@rogue.local"}
               })
    end
  end

  describe "description/0" do
    test "returns a string" do
      assert is_binary(ReceiveFromWorkflow.description())
    end
  end

  describe "routes/0" do
    test "returns expected routes" do
      assert [:on_success, :on_error] = ReceiveFromWorkflow.routes()
    end
  end
end
