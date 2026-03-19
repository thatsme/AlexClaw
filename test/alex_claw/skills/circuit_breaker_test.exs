defmodule AlexClaw.Skills.CircuitBreakerTest do
  use ExUnit.Case, async: false

  alias AlexClaw.Skills.CircuitBreaker
  alias AlexClaw.Skills.CircuitBreakerSupervisor

  setup do
    # Clean up any existing breaker for the test skill
    on_exit(fn ->
      CircuitBreakerSupervisor.stop_breaker("test_skill")
    end)

    :ok
  end

  describe "initial state" do
    test "fresh breaker starts in :closed state" do
      {:ok, _pid} = CircuitBreakerSupervisor.ensure_started("test_skill")

      assert {:closed, 0, nil} = CircuitBreaker.state("test_skill")
      assert CircuitBreaker.allow?("test_skill")
    end

    test "unknown skill returns :unknown state" do
      assert :unknown = CircuitBreaker.state("nonexistent_skill")
    end

    test "unknown skill is allowed (no breaker = no restriction)" do
      assert CircuitBreaker.allow?("nonexistent_skill")
    end
  end

  describe "call/2 transparent wrapper" do
    test "successful call returns result unchanged" do
      assert {:ok, "hello"} = CircuitBreaker.call("test_skill", fn -> {:ok, "hello"} end)
      assert {:closed, 0, nil} = CircuitBreaker.state("test_skill")
    end

    test "failed call returns error unchanged" do
      assert {:error, :timeout} = CircuitBreaker.call("test_skill", fn -> {:error, :timeout} end)
    end

    test "ensure_started is idempotent" do
      {:ok, pid1} = CircuitBreakerSupervisor.ensure_started("test_skill")
      {:ok, pid2} = CircuitBreakerSupervisor.ensure_started("test_skill")
      assert pid1 == pid2
    end
  end

  describe "state transitions" do
    test "3 consecutive failures open the circuit" do
      for _ <- 1..3 do
        CircuitBreaker.call("test_skill", fn -> {:error, :service_unavailable} end)
      end

      # Give the GenServer time to process the casts
      Process.sleep(50)

      assert {:open, 3, :service_unavailable} = CircuitBreaker.state("test_skill")
      refute CircuitBreaker.allow?("test_skill")
    end

    test "circuit open returns :circuit_open without calling the function" do
      for _ <- 1..3 do
        CircuitBreaker.call("test_skill", fn -> {:error, :boom} end)
      end

      Process.sleep(50)

      # This function should never be called
      result = CircuitBreaker.call("test_skill", fn -> {:ok, "should not run"} end)
      assert {:error, :circuit_open} = result
    end

    test "success resets failure count in :closed state" do
      CircuitBreaker.call("test_skill", fn -> {:error, :fail1} end)
      CircuitBreaker.call("test_skill", fn -> {:error, :fail2} end)
      Process.sleep(50)

      assert {:closed, 2, _} = CircuitBreaker.state("test_skill")

      CircuitBreaker.call("test_skill", fn -> {:ok, "recovered"} end)
      Process.sleep(50)

      assert {:closed, 0, nil} = CircuitBreaker.state("test_skill")
    end

    test "half_open transitions to :closed on success" do
      # Use short timeout via process message simulation
      {:ok, _} = CircuitBreakerSupervisor.ensure_started("test_skill")

      for _ <- 1..3 do
        CircuitBreaker.call("test_skill", fn -> {:error, :boom} end)
      end

      Process.sleep(50)
      assert {:open, _, _} = CircuitBreaker.state("test_skill")

      # Simulate the timer firing
      [{pid, _}] = Registry.lookup(AlexClaw.CircuitBreakerRegistry, "test_skill")
      send(pid, :half_open)
      Process.sleep(50)

      assert {:half_open, 0, nil} = CircuitBreaker.state("test_skill")
      assert CircuitBreaker.allow?("test_skill")

      # Success in half_open closes the circuit
      CircuitBreaker.call("test_skill", fn -> {:ok, "test"} end)
      Process.sleep(50)

      assert {:closed, 0, nil} = CircuitBreaker.state("test_skill")
    end

    test "half_open transitions back to :open on failure" do
      {:ok, _} = CircuitBreakerSupervisor.ensure_started("test_skill")

      for _ <- 1..3 do
        CircuitBreaker.call("test_skill", fn -> {:error, :boom} end)
      end

      Process.sleep(50)

      [{pid, _}] = Registry.lookup(AlexClaw.CircuitBreakerRegistry, "test_skill")
      send(pid, :half_open)
      Process.sleep(50)

      assert {:half_open, _, _} = CircuitBreaker.state("test_skill")

      CircuitBreaker.call("test_skill", fn -> {:error, :still_broken} end)
      Process.sleep(50)

      assert {:open, _, :still_broken} = CircuitBreaker.state("test_skill")
      refute CircuitBreaker.allow?("test_skill")
    end
  end

  describe "reset/1" do
    test "resets from :open to :closed" do
      for _ <- 1..3 do
        CircuitBreaker.call("test_skill", fn -> {:error, :boom} end)
      end

      Process.sleep(50)
      assert {:open, _, _} = CircuitBreaker.state("test_skill")

      CircuitBreaker.reset("test_skill")

      assert {:closed, 0, nil} = CircuitBreaker.state("test_skill")
      assert CircuitBreaker.allow?("test_skill")
    end

    test "reset on nonexistent breaker is a no-op" do
      assert :ok = CircuitBreaker.reset("nonexistent_skill")
    end
  end

  describe "stop_breaker/1" do
    test "removes the breaker and cleans up ETS" do
      {:ok, _} = CircuitBreakerSupervisor.ensure_started("test_skill")
      assert {:closed, _, _} = CircuitBreaker.state("test_skill")

      CircuitBreakerSupervisor.stop_breaker("test_skill")

      assert :unknown = CircuitBreaker.state("test_skill")
    end
  end
end
