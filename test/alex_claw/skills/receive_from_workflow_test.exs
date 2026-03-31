defmodule AlexClaw.Skills.ReceiveFromWorkflowTest do
  use ExUnit.Case, async: true
  @moduletag :unit

  alias AlexClaw.Skills.ReceiveFromWorkflow

  describe "run/1" do
    test "passes through input on success" do
      assert {:ok, "hello", :on_success} =
               ReceiveFromWorkflow.run(%{input: "hello", config: %{}})
    end

    test "rejects nil input" do
      assert {:error, :no_input_received} =
               ReceiveFromWorkflow.run(%{input: nil, config: %{}})
    end

    test "rejects missing input key" do
      assert {:error, :no_input_received} =
               ReceiveFromWorkflow.run(%{config: %{}})
    end

    test "accepts any node when allowed_nodes is empty" do
      assert {:ok, "data", :on_success} =
               ReceiveFromWorkflow.run(%{
                 input: "data",
                 config: %{"allowed_nodes" => [], "_source_node" => "unknown@node"}
               })
    end

    test "accepts any node when allowed_nodes is nil" do
      assert {:ok, "data", :on_success} =
               ReceiveFromWorkflow.run(%{
                 input: "data",
                 config: %{"_source_node" => "unknown@node"}
               })
    end

    test "accepts node in allowed_nodes list" do
      assert {:ok, "data", :on_success} =
               ReceiveFromWorkflow.run(%{
                 input: "data",
                 config: %{
                   "allowed_nodes" => ["alexclaw@node1.local", "alexclaw@node2.local"],
                   "_source_node" => "alexclaw@node1.local"
                 }
               })
    end

    test "rejects node not in allowed_nodes list" do
      assert {:error, {:unauthorized_node, "alexclaw@rogue.local"}} =
               ReceiveFromWorkflow.run(%{
                 input: "data",
                 config: %{
                   "allowed_nodes" => ["alexclaw@node1.local"],
                   "_source_node" => "alexclaw@rogue.local"
                 }
               })
    end

    test "preserves complex input data" do
      input = %{"results" => [1, 2, 3], "metadata" => %{"source" => "test"}}

      assert {:ok, ^input, :on_success} =
               ReceiveFromWorkflow.run(%{input: input, config: %{}})
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
