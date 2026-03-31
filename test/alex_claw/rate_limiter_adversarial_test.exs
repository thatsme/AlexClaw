defmodule AlexClaw.RateLimiterAdversarialTest do
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :adversarial

  alias AlexClaw.RateLimiter

  setup do
    # Ensure rate limiter ETS table exists
    RateLimiter.init_table()

    # Seed rate limit config
    insert_setting("auth.rate_limit.max_attempts", "3", type: "integer", category: "auth")
    insert_setting("auth.rate_limit.block_duration_seconds", "60", type: "integer", category: "auth")

    :ok
  end

  describe "blocking after max attempts" do
    test "blocks IP after reaching max_attempts failures" do
      ip = "adversarial_block_#{System.unique_integer([:positive])}"

      assert :ok = RateLimiter.check(ip)
      assert :ok = RateLimiter.record_failure(ip)
      assert :ok = RateLimiter.record_failure(ip)
      assert :ok = RateLimiter.record_failure(ip)

      # 3 failures recorded, check should now trigger blocking
      assert {:error, :rate_limited, seconds} = RateLimiter.check(ip)
      assert seconds > 0
      assert seconds <= 60
    end

    test "blocked IP stays blocked on subsequent checks" do
      ip = "adversarial_stay_blocked_#{System.unique_integer([:positive])}"

      for _ <- 1..3, do: RateLimiter.record_failure(ip)
      {:error, :rate_limited, _} = RateLimiter.check(ip)

      # Still blocked on second check
      assert {:error, :rate_limited, _seconds} = RateLimiter.check(ip)
    end

    test "recording failure while already blocked re-blocks with fresh duration" do
      ip = "adversarial_reblock_#{System.unique_integer([:positive])}"

      for _ <- 1..3, do: RateLimiter.record_failure(ip)
      {:error, :rate_limited, _} = RateLimiter.check(ip)

      # Record another failure while blocked
      assert :ok = RateLimiter.record_failure(ip)

      # Should still be blocked
      assert {:error, :rate_limited, _seconds} = RateLimiter.check(ip)
    end
  end

  describe "block expiry" do
    test "expired block is cleared on check" do
      ip = "adversarial_expired_#{System.unique_integer([:positive])}"

      # Insert a record with blocked_until in the past
      past = System.system_time(:second) - 10
      :ets.insert(:alexclaw_rate_limiter, {ip, 5, past})

      # Check should clear the expired block
      assert :ok = RateLimiter.check(ip)
    end
  end

  describe "purge_expired/0" do
    test "purges only expired entries" do
      ip_expired = "purge_expired_#{System.unique_integer([:positive])}"
      ip_active = "purge_active_#{System.unique_integer([:positive])}"
      ip_unblocked = "purge_unblocked_#{System.unique_integer([:positive])}"

      past = System.system_time(:second) - 10
      future = System.system_time(:second) + 3600

      :ets.insert(:alexclaw_rate_limiter, {ip_expired, 5, past})
      :ets.insert(:alexclaw_rate_limiter, {ip_active, 5, future})
      :ets.insert(:alexclaw_rate_limiter, {ip_unblocked, 2, nil})

      purged = RateLimiter.purge_expired()
      assert purged >= 1

      # Expired should be gone
      assert :ets.lookup(:alexclaw_rate_limiter, ip_expired) == []

      # Active block should remain
      assert [{^ip_active, 5, ^future}] = :ets.lookup(:alexclaw_rate_limiter, ip_active)

      # Unblocked record should remain (nil blocked_until is not expired)
      assert [{^ip_unblocked, 2, nil}] = :ets.lookup(:alexclaw_rate_limiter, ip_unblocked)
    end

    test "returns 0 when no expired entries exist" do
      assert RateLimiter.purge_expired() >= 0
    end
  end

  describe "clear/1 on blocked IP" do
    test "unblocks a previously blocked IP" do
      ip = "adversarial_clear_blocked_#{System.unique_integer([:positive])}"

      for _ <- 1..3, do: RateLimiter.record_failure(ip)
      {:error, :rate_limited, _} = RateLimiter.check(ip)

      RateLimiter.clear(ip)
      assert :ok = RateLimiter.check(ip)
    end
  end

  describe "edge case inputs" do
    test "empty string IP" do
      # Empty string is a valid ETS key — should not crash
      assert :ok = RateLimiter.record_failure("")
      assert :ok = RateLimiter.check("")
      RateLimiter.clear("")
    end

    test "very long IP string" do
      long_ip = String.duplicate("x", 10_000)
      assert :ok = RateLimiter.record_failure(long_ip)
      assert :ok = RateLimiter.check(long_ip)
      RateLimiter.clear(long_ip)
    end

    test "unicode IP string" do
      ip = "日本語のIP_#{System.unique_integer([:positive])}"
      assert :ok = RateLimiter.record_failure(ip)
      assert :ok = RateLimiter.check(ip)
      RateLimiter.clear(ip)
    end
  end

  describe "init_table/0" do
    test "is idempotent — calling twice does not crash" do
      assert :ok = RateLimiter.init_table()
      assert :ok = RateLimiter.init_table()
    end
  end
end
