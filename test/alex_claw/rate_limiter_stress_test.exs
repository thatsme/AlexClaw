defmodule AlexClaw.RateLimiterStressTest do
  use AlexClaw.DataCase, async: false
  @moduletag :stress
  @moduletag :adversarial

  alias AlexClaw.RateLimiter

  setup do
    RateLimiter.init_table()

    # Use high threshold so we can measure count accumulation
    insert_setting("auth.rate_limit.max_attempts", "200", type: "integer", category: "auth")
    insert_setting("auth.rate_limit.block_duration_seconds", "60", type: "integer", category: "auth")

    :ok
  end

  describe "concurrent record_failure on same IP" do
    test "100 concurrent failures all succeed without crash" do
      ip = "stress_same_ip_#{System.unique_integer([:positive])}"

      tasks =
        for _ <- 1..100 do
          Task.async(fn -> RateLimiter.record_failure(ip) end)
        end

      results = Task.await_many(tasks, 5_000)

      # All calls should return :ok
      assert Enum.all?(results, &(&1 == :ok))

      # ETS should have the IP with some count > 0
      # Due to read-modify-write race, count may be less than 100
      [{^ip, count, _}] = :ets.lookup(:alexclaw_rate_limiter, ip)
      assert count > 0
      assert count <= 100
    end
  end

  describe "concurrent check + record_failure mix" do
    test "50 readers and 50 writers do not crash" do
      ip = "stress_mix_#{System.unique_integer([:positive])}"

      writers =
        for _ <- 1..50 do
          Task.async(fn -> RateLimiter.record_failure(ip) end)
        end

      readers =
        for _ <- 1..50 do
          Task.async(fn -> RateLimiter.check(ip) end)
        end

      write_results = Task.await_many(writers, 5_000)
      read_results = Task.await_many(readers, 5_000)

      assert Enum.all?(write_results, &(&1 == :ok))

      # Reads should all return either :ok or {:error, :rate_limited, _}
      assert Enum.all?(read_results, fn
        :ok -> true
        {:error, :rate_limited, _} -> true
        _ -> false
      end)
    end
  end

  describe "purge_expired under concurrent writes" do
    test "purge does not crash while writes are happening" do
      # Pre-populate with some expired entries
      now = System.system_time(:second)

      for i <- 1..20 do
        :ets.insert(:alexclaw_rate_limiter, {"expired_#{i}", 5, now - 100})
      end

      # Concurrent writers adding new entries
      writers =
        for i <- 1..50 do
          Task.async(fn ->
            ip = "concurrent_write_#{i}_#{System.unique_integer([:positive])}"
            RateLimiter.record_failure(ip)
          end)
        end

      # Run purge while writers are active
      purge_task = Task.async(fn -> RateLimiter.purge_expired() end)

      write_results = Task.await_many(writers, 5_000)
      purge_result = Task.await(purge_task, 5_000)

      assert Enum.all?(write_results, &(&1 == :ok))
      assert is_integer(purge_result)
      assert purge_result >= 0
    end
  end

  describe "concurrent clear operations" do
    test "clearing the same IP from multiple processes" do
      ip = "stress_clear_#{System.unique_integer([:positive])}"
      RateLimiter.record_failure(ip)

      tasks =
        for _ <- 1..50 do
          Task.async(fn -> RateLimiter.clear(ip) end)
        end

      results = Task.await_many(tasks, 5_000)
      assert Enum.all?(results, &(&1 == :ok))
      assert :ok = RateLimiter.check(ip)
    end
  end
end
