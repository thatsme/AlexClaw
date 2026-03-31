defmodule AlexClaw.Skills.CircuitBreakerStressTest do
  use ExUnit.Case, async: false
  @moduletag :stress

  alias AlexClaw.Skills.CircuitBreaker
  alias AlexClaw.Skills.CircuitBreakerSupervisor

  setup do
    breaker_name = "stress_breaker_#{System.unique_integer([:positive])}"
    CircuitBreakerSupervisor.ensure_started(breaker_name)

    on_exit(fn ->
      try do
        CircuitBreakerSupervisor.stop_breaker(breaker_name)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end)

    %{breaker: breaker_name}
  end

  describe "rapid call cycles" do
    test "breaker handles rapid success/failure via call/2", %{breaker: breaker} do
      # Use CircuitBreaker.call/2 which is the public API.
      # Alternate between functions that succeed and fail.
      tasks =
        for i <- 1..100 do
          Task.async(fn ->
            if rem(i, 2) == 0 do
              CircuitBreaker.call(breaker, fn -> {:ok, "success", :done} end)
            else
              CircuitBreaker.call(breaker, fn -> {:error, :boom} end)
            end
          end)
        end

      results = Task.await_many(tasks, 10_000)
      assert length(results) == 100

      # Each result should be a valid return type
      assert Enum.all?(results, fn
        {:ok, _, _} -> true
        {:error, _} -> true
        {:error, :circuit_open} -> true
      end)

      # Breaker should be in a valid state
      # state/1 returns {atom, count, last_error} or :unknown
      case CircuitBreaker.state(breaker) do
        {s, _count, _err} -> assert s in [:closed, :open, :half_open]
        :unknown -> flunk("Breaker state should not be :unknown after calls")
      end
    end
  end

  describe "concurrent allow? checks" do
    test "100 concurrent allow? calls do not crash", %{breaker: breaker} do
      tasks =
        for _ <- 1..100 do
          Task.async(fn -> CircuitBreaker.allow?(breaker) end)
        end

      results = Task.await_many(tasks, 5_000)

      assert Enum.all?(results, fn r -> is_boolean(r) end)
    end
  end

  describe "concurrent state queries" do
    test "state queries during call/2 mutations do not crash", %{breaker: breaker} do
      writers =
        for _ <- 1..50 do
          Task.async(fn ->
            CircuitBreaker.call(breaker, fn -> {:error, :fail} end)
          end)
        end

      readers =
        for _ <- 1..50 do
          Task.async(fn -> CircuitBreaker.state(breaker) end)
        end

      Task.await_many(writers, 5_000)
      states = Task.await_many(readers, 5_000)

      assert Enum.all?(states, fn
        {s, _count, _err} -> s in [:closed, :open, :half_open]
        :unknown -> true
      end)
    end
  end
end
