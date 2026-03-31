defmodule AlexClaw.Skills.CircuitBreakerTest do
  use ExUnit.Case, async: false
  @moduletag :integration

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

      assert {:open, 3, :still_broken} = CircuitBreaker.state("test_skill")
      refute CircuitBreaker.allow?("test_skill")
    end

    test "circuit open does not invoke the function" do
      for _ <- 1..3 do
        CircuitBreaker.call("test_skill", fn -> {:error, :boom} end)
      end

      Process.sleep(50)

      test_pid = self()

      result =
        CircuitBreaker.call("test_skill", fn ->
          send(test_pid, :function_was_called)
          {:ok, "should not run"}
        end)

      assert {:error, :circuit_open} = result
      refute_received :function_was_called
    end
  end

  describe "isolation" do
    setup do
      on_exit(fn ->
        CircuitBreakerSupervisor.stop_breaker("skill_a")
        CircuitBreakerSupervisor.stop_breaker("skill_b")
      end)

      :ok
    end

    test "multiple skills have independent circuits" do
      # Open circuit for skill_a
      for _ <- 1..3 do
        CircuitBreaker.call("skill_a", fn -> {:error, :fail} end)
      end

      Process.sleep(50)

      refute CircuitBreaker.allow?("skill_a")
      assert CircuitBreaker.allow?("skill_b")

      # skill_b should still work
      assert {:ok, "works"} = CircuitBreaker.call("skill_b", fn -> {:ok, "works"} end)
    end
  end

  describe "reset/1" do
    test "reset from :closed is a no-op" do
      on_exit(fn -> CircuitBreakerSupervisor.stop_breaker("reset_noop_skill") end)

      CircuitBreaker.call("reset_noop_skill", fn -> {:ok, "fine"} end)
      Process.sleep(50)

      CircuitBreaker.reset("reset_noop_skill")
      assert {:closed, 0, nil} = CircuitBreaker.state("reset_noop_skill")
    end
    test "resets from :open to :closed" do
      # Use a dedicated skill name to avoid test ordering issues
      on_exit(fn -> CircuitBreakerSupervisor.stop_breaker("reset_skill") end)

      for _ <- 1..3 do
        CircuitBreaker.call("reset_skill", fn -> {:error, :boom} end)
      end

      Process.sleep(50)
      assert {:open, _, _} = CircuitBreaker.state("reset_skill")

      CircuitBreaker.reset("reset_skill")

      assert {:closed, 0, nil} = CircuitBreaker.state("reset_skill")
      assert CircuitBreaker.allow?("reset_skill")
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

    test "stop_breaker on nonexistent skill is a no-op" do
      assert :ok = CircuitBreakerSupervisor.stop_breaker("nonexistent_skill")
    end
  end

  describe "PubSub lifecycle" do
    setup do
      on_exit(fn ->
        CircuitBreakerSupervisor.stop_breaker("lifecycle_skill")
      end)

      :ok
    end

    test "skill_unregistered cleans up breaker" do
      {:ok, _} = CircuitBreakerSupervisor.ensure_started("lifecycle_skill")
      assert {:closed, _, _} = CircuitBreaker.state("lifecycle_skill")

      Phoenix.PubSub.broadcast(AlexClaw.PubSub, "skills:registry", {:skill_unregistered, "lifecycle_skill"})
      Process.sleep(50)

      assert :unknown = CircuitBreaker.state("lifecycle_skill")
    end

    test "skill_registered resets existing breaker" do
      # Open the circuit
      for _ <- 1..3 do
        CircuitBreaker.call("lifecycle_skill", fn -> {:error, :fail} end)
      end

      Process.sleep(50)
      assert {:open, _, _} = CircuitBreaker.state("lifecycle_skill")

      # Simulate skill reload
      Phoenix.PubSub.broadcast(AlexClaw.PubSub, "skills:registry", {:skill_registered, "lifecycle_skill"})
      Process.sleep(50)

      assert {:closed, 0, nil} = CircuitBreaker.state("lifecycle_skill")
    end

    test "skill_registered on nonexistent breaker is a no-op" do
      Phoenix.PubSub.broadcast(AlexClaw.PubSub, "skills:registry", {:skill_registered, "never_started_skill"})
      Process.sleep(50)

      assert :unknown = CircuitBreaker.state("never_started_skill")
    end
  end
end
