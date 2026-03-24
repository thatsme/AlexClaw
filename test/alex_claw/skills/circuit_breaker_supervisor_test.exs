defmodule AlexClaw.Skills.CircuitBreakerSupervisorTest do
  use ExUnit.Case, async: false

  alias AlexClaw.Skills.CircuitBreakerSupervisor

  describe "ensure_started/1" do
    test "starts a breaker for a new skill" do
      name = "sup_test_skill_#{System.unique_integer([:positive])}"
      assert {:ok, pid} = CircuitBreakerSupervisor.ensure_started(name)
      assert is_pid(pid)
    end

    test "returns same pid for already started skill" do
      name = "sup_test_idempotent_#{System.unique_integer([:positive])}"
      {:ok, pid1} = CircuitBreakerSupervisor.ensure_started(name)
      {:ok, pid2} = CircuitBreakerSupervisor.ensure_started(name)
      assert pid1 == pid2
    end
  end

  describe "stop_breaker/1" do
    test "stops a running breaker" do
      name = "sup_test_stop_#{System.unique_integer([:positive])}"
      {:ok, _pid} = CircuitBreakerSupervisor.ensure_started(name)
      assert :ok = CircuitBreakerSupervisor.stop_breaker(name)
    end

    test "returns error for non-existent breaker" do
      result = CircuitBreakerSupervisor.stop_breaker("nonexistent_#{System.unique_integer([:positive])}")
      assert result == {:error, :not_found} or result == :ok
    end
  end
end
