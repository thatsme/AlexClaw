defmodule AlexClaw.LLM.UsageTrackerTest do
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.LLM.UsageTracker

  describe "persist/1" do
    test "persists usage for a provider without crashing" do
      # Create a test provider first
      {:ok, provider} = AlexClaw.LLM.create_provider(%{
        name: "tracker_test_#{System.unique_integer([:positive])}",
        type: "openai_compatible",
        host: "http://localhost:9999",
        model: "test",
        tier: "light",
        enabled: true,
        priority: 50
      })

      assert :ok = UsageTracker.persist(provider.id)
    end
  end

  describe "GenServer" do
    test "is running" do
      assert Process.whereis(UsageTracker) != nil
    end
  end
end
