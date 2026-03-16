defmodule AlexClaw.Skills.GoogleTasksTest do
  use AlexClaw.DataCase, async: false

  alias AlexClaw.Skills.GoogleTasks

  setup do
    case :ets.info(:google_token_cache) do
      :undefined -> :ets.new(:google_token_cache, [:named_table, :public, :set])
      _ -> :ok
    end

    :ets.insert(:google_token_cache, {:access_token, "fake-test-token", System.monotonic_time(:second) + 3600})

    on_exit(fn ->
      case :ets.info(:google_token_cache) do
        :undefined -> :ok
        _ -> :ets.delete_all_objects(:google_token_cache)
      end
    end)

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
      :ets.delete_all_objects(:google_token_cache)

      result = GoogleTasks.run(%{config: %{"action" => "list"}})
      assert {:error, _} = result
    end
  end

end
