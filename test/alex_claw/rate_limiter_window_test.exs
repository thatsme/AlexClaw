defmodule AlexClaw.RateLimiterWindowTest do
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.RateLimiter

  setup do
    RateLimiter.init_table()
    insert_setting("auth.rate_limit.max_attempts", "3", type: "integer", category: "auth")

    insert_setting("auth.rate_limit.block_duration_seconds", "60",
      type: "integer",
      category: "auth"
    )

    insert_setting("auth.rate_limit.window_seconds", "300", type: "integer", category: "auth")

    :ok
  end

  defp ip, do: "window_#{System.unique_integer([:positive])}"

  defp age(ip, seconds) do
    now = System.system_time(:second)
    [{^ip, attempts, blocked_until, _first}] = :ets.lookup(:alexclaw_rate_limiter, ip)
    :ets.insert(:alexclaw_rate_limiter, {ip, attempts, blocked_until, now - seconds})
  end

  # Before the window existed the count never decayed: an IP that failed three
  # times a year ago was one attempt from a block forever.
  describe "attempts outside the window do not accumulate" do
    test "a failure after the window starts a fresh count" do
      ip = ip()
      for _ <- 1..2, do: RateLimiter.record_failure(ip)
      age(ip, 400)

      RateLimiter.record_failure(ip)

      assert [{^ip, 1, nil, _first}] = :ets.lookup(:alexclaw_rate_limiter, ip)
      assert :ok = RateLimiter.check(ip)
    end

    test "a stale count is dropped on check rather than blocking" do
      ip = ip()
      for _ <- 1..3, do: RateLimiter.record_failure(ip)
      age(ip, 400)

      assert :ok = RateLimiter.check(ip)
      assert :ets.lookup(:alexclaw_rate_limiter, ip) == []
    end

    test "purge_expired drops a stale unblocked count" do
      ip = ip()
      RateLimiter.record_failure(ip)
      age(ip, 400)

      assert RateLimiter.purge_expired() >= 1
      assert :ets.lookup(:alexclaw_rate_limiter, ip) == []
    end
  end

  describe "attempts inside the window still block" do
    test "max_attempts failures within the window block the IP" do
      ip = ip()
      for _ <- 1..3, do: RateLimiter.record_failure(ip)

      assert {:error, :rate_limited, _seconds} = RateLimiter.check(ip)
    end

    test "failures spread across the window keep accumulating" do
      ip = ip()
      RateLimiter.record_failure(ip)
      age(ip, 200)
      RateLimiter.record_failure(ip)
      RateLimiter.record_failure(ip)

      assert {:error, :rate_limited, _seconds} = RateLimiter.check(ip)
    end

    test "the window is read from config, not hardcoded" do
      insert_setting("auth.rate_limit.window_seconds", "60", type: "integer", category: "auth")
      ip = ip()
      for _ <- 1..3, do: RateLimiter.record_failure(ip)
      age(ip, 90)

      assert :ok = RateLimiter.check(ip)
    end
  end
end
