defmodule AlexClaw.Google.OAuthStateTest do
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Google.TokenManager

  defp state, do: "state_#{System.unique_integer([:positive])}"

  # The CSRF state table was created by whichever request started a flow first.
  # If that was a controller or LiveView process, its exit took every in-flight
  # authorization with it.
  describe "state survives the process that created it" do
    test "put from a task that then exits is still redeemable" do
      oauth_state = state()

      task = Task.async(fn -> TokenManager.put_state(oauth_state, "chat-1") end)
      :ok = Task.await(task)

      refute Process.alive?(task.pid)
      assert {:ok, "chat-1"} = TokenManager.take_state(oauth_state)
    end
  end

  # A CSRF state is single-use. Redeeming it twice would let a replayed
  # callback through.
  describe "a state is consumed exactly once" do
    test "the second take reports it unknown" do
      oauth_state = state()
      TokenManager.put_state(oauth_state, "chat-2")

      assert {:ok, "chat-2"} = TokenManager.take_state(oauth_state)
      assert :error = TokenManager.take_state(oauth_state)
    end

    test "concurrent takes yield exactly one success" do
      oauth_state = state()
      TokenManager.put_state(oauth_state, "chat-3")

      results =
        1..10
        |> Enum.map(fn _ -> Task.async(fn -> TokenManager.take_state(oauth_state) end) end)
        |> Task.await_many(5_000)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &(&1 == :error)) == 9
    end

    test "an unknown state is refused" do
      assert :error = TokenManager.take_state(state())
    end
  end

  describe "the state table is protected" do
    test "a non-owner write raises" do
      assert_raise ArgumentError, fn ->
        :ets.insert(:google_oauth_states, {"forged", "chat", 0})
      end
    end
  end
end
