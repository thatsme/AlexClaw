defmodule AlexClaw.Skills.GoogleTasksTest do
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Google.TokenManager
  alias AlexClaw.Skills.GoogleTasks

  # The token cache is :private, so a token gets in through its owner or not at
  # all. TokenManager.seed_token/2 is compiled under MIX_ENV=test only.
  setup do
    TokenManager.seed_token("fake-test-token", System.monotonic_time(:second) + 3600)

    on_exit(fn -> TokenManager.clear_token() end)

    bypass = Bypass.open()
    {:ok, bypass: bypass}
  end

  describe "run/1 — unknown action" do
    test "returns error for unknown action" do
      result = GoogleTasks.run(%{config: %{"action" => "purge"}})
      assert {:error, {:unknown_action, "purge"}} = result
    end
  end

  describe "run/1 — add action" do
    test "returns error when no title provided" do
      result = GoogleTasks.run(%{config: %{"action" => "add"}, input: nil})
      assert {:error, :no_task_title} = result
    end

    test "returns error when title is empty string" do
      result = GoogleTasks.run(%{config: %{"action" => "add"}, input: ""})
      assert {:error, :no_task_title} = result
    end
  end

  describe "run/1 — no token" do
    test "returns error when no OAuth token available" do
      TokenManager.clear_token()

      result = GoogleTasks.run(%{config: %{"action" => "list"}})
      assert {:error, _} = result
    end
  end
end
