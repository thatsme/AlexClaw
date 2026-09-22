defmodule AlexClaw.Skills.ForgeGuardTest do
  @moduledoc """
  One skill generation at a time, a hard cap on attempts, and a deadline across
  them. An unbounded Forge retry loop against two local model servers held the
  GPU until the host had to be powered off.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Skills.{Coder, ForgeGuard}

  # A process that takes the lock and holds it until told to stop.
  defp holder do
    test = self()

    pid =
      spawn(fn ->
        send(test, {:acquired, ForgeGuard.acquire()})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:acquired, :ok}
    pid
  end

  defp stop(pid) do
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, _, _}
  end

  describe "the lock" do
    test "a second generation is refused while one runs, and allowed after" do
      pid = holder()
      assert ForgeGuard.acquire() == {:error, :forge_busy}

      ForgeGuard.release(pid)
      assert ForgeGuard.acquire() == :ok
      ForgeGuard.release()
      stop(pid)
    end

    test "the holder asking again is refused: one generation per owner too" do
      assert ForgeGuard.acquire() == :ok
      assert ForgeGuard.acquire() == {:error, :forge_busy}
      ForgeGuard.release()
    end

    test "releasing a lock held by someone else does nothing" do
      pid = holder()
      assert ForgeGuard.release() == :ok
      assert ForgeGuard.acquire() == {:error, :forge_busy}
      stop(pid)
    end

    test "the lock is freed when its holder exits without releasing" do
      pid = holder()
      stop(pid)
      assert ForgeGuard.acquire() == :ok
      ForgeGuard.release()
    end

    test "run/1 releases after the function returns" do
      assert ForgeGuard.run(fn -> :done end) == :done
      assert ForgeGuard.acquire() == :ok
      ForgeGuard.release()
    end

    test "the Coder skill refuses a generation while another runs" do
      pid = holder()
      assert Coder.run(%{input: "a skill that returns the time"}) == {:error, :forge_busy}
      stop(pid)
    end
  end

  describe "attempts" do
    test "a request above the cap is held to the cap" do
      assert ForgeGuard.attempts(50) == ForgeGuard.max_attempts()
      assert ForgeGuard.attempts(ForgeGuard.max_attempts()) == ForgeGuard.max_attempts()
    end

    test "zero, a negative or a non-integer request still gets bounded attempts" do
      assert ForgeGuard.attempts(0) == 1
      assert ForgeGuard.attempts(-1) == 1
      assert ForgeGuard.attempts(nil) == ForgeGuard.max_attempts()
      assert ForgeGuard.attempts("3") == ForgeGuard.max_attempts()
    end
  end

  describe "the time budget" do
    test "a deadline in the past has expired; one in the future has not" do
      now = System.monotonic_time(:millisecond)
      assert ForgeGuard.expired?(now - 1)
      refute ForgeGuard.expired?(now + 60_000)
    end

    test "a fresh deadline lies the budget ahead" do
      now = System.monotonic_time(:millisecond)
      ahead = ForgeGuard.deadline() - now
      assert_in_delta ahead, ForgeGuard.budget_seconds() * 1000, 1_000
    end

    test "an unset or invalid budget falls back to the default" do
      AlexClaw.Config.set("forge.time_budget_seconds", "0", type: "integer")
      assert ForgeGuard.budget_seconds() == 600
      AlexClaw.Config.delete("forge.time_budget_seconds")
      assert ForgeGuard.budget_seconds() == 600
    end
  end
end
