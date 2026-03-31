defmodule AlexClaw.Skills.SendToWorkflowTest do
  use ExUnit.Case, async: true
  @moduletag :unit

  alias AlexClaw.Skills.SendToWorkflow

  describe "run/1 config validation" do
    test "rejects missing target_node" do
      assert {:error, :missing_target_node} =
               SendToWorkflow.run(%{
                 input: "data",
                 config: %{"target_workflow" => "some_workflow"}
               })
    end

    test "rejects empty target_node" do
      assert {:error, :missing_target_node} =
               SendToWorkflow.run(%{
                 input: "data",
                 config: %{"target_node" => "", "target_workflow" => "some_workflow"}
               })
    end

    test "rejects missing target_workflow" do
      assert {:error, :missing_target_workflow} =
               SendToWorkflow.run(%{
                 input: "data",
                 config: %{"target_node" => "alexclaw@node2.local"}
               })
    end

    test "rejects empty target_workflow" do
      assert {:error, :missing_target_workflow} =
               SendToWorkflow.run(%{
                 input: "data",
                 config: %{"target_node" => "alexclaw@node2.local", "target_workflow" => ""}
               })
    end

    test "rejects nil config" do
      assert {:error, :missing_target_node} =
               SendToWorkflow.run(%{input: "data"})
    end
  end

  describe "run/1 RPC failure" do
    test "returns rpc_failed for unreachable node" do
      assert {:error, {:rpc_failed, _reason}} =
               SendToWorkflow.run(%{
                 input: "data",
                 config: %{
                   "target_node" => "nonexistent@nowhere.local",
                   "target_workflow" => "test",
                   "timeout" => 1_000
                 }
               })
    end
  end

  describe "description/0" do
    test "returns a string" do
      assert is_binary(SendToWorkflow.description())
    end
  end

  describe "routes/0" do
    test "returns expected routes" do
      assert [:on_sent, :on_error] = SendToWorkflow.routes()
    end
  end
end
