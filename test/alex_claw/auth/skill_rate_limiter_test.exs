defmodule AlexClaw.Auth.SkillRateLimiterTest do
  use ExUnit.Case, async: true

  alias AlexClaw.Auth.SkillRateLimiter

  defp unique_key(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  describe "check/4" do
    test "returns :ok when under the threshold" do
      key = unique_key("under")
      assert :ok = SkillRateLimiter.check(key, :perm, 5, 60)
      assert :ok = SkillRateLimiter.check(key, :perm, 5, 60)
      assert :ok = SkillRateLimiter.check(key, :perm, 5, 60)
    end

    test "returns :ok at exactly the threshold (N calls allowed)" do
      key = unique_key("at")

      for _ <- 1..5 do
        assert :ok = SkillRateLimiter.check(key, :perm, 5, 60)
      end
    end

    test "returns {:error, :rate_limited} after the (N+1)th call" do
      key = unique_key("over")

      for _ <- 1..5 do
        assert :ok = SkillRateLimiter.check(key, :perm, 5, 60)
      end

      assert {:error, :rate_limited} = SkillRateLimiter.check(key, :perm, 5, 60)
      assert {:error, :rate_limited} = SkillRateLimiter.check(key, :perm, 5, 60)
    end

    test "old timestamps fall out of the sliding window" do
      key = unique_key("expiry")

      # Fill the window with a tight 1-second TTL.
      assert :ok = SkillRateLimiter.check(key, :perm, 2, 1)
      assert :ok = SkillRateLimiter.check(key, :perm, 2, 1)
      assert {:error, :rate_limited} = SkillRateLimiter.check(key, :perm, 2, 1)

      # The filter is `>= now - window_seconds`, so a 1s window holds timestamps
      # for the full second after `now` advances past `window_start`. Sleeping
      # 2.1s guarantees the old entries fall outside the window.
      Process.sleep(2_100)
      assert :ok = SkillRateLimiter.check(key, :perm, 2, 1)
    end

    test "distinct caller keys have independent counters" do
      key_a = unique_key("a")
      key_b = unique_key("b")

      for _ <- 1..3, do: assert(:ok = SkillRateLimiter.check(key_a, :perm, 3, 60))
      assert {:error, :rate_limited} = SkillRateLimiter.check(key_a, :perm, 3, 60)

      # key_b's bucket is untouched.
      assert :ok = SkillRateLimiter.check(key_b, :perm, 3, 60)
    end

    test "distinct permissions on the same key have independent counters" do
      key = unique_key("perm-iso")

      for _ <- 1..3, do: assert(:ok = SkillRateLimiter.check(key, :perm_a, 3, 60))
      assert {:error, :rate_limited} = SkillRateLimiter.check(key, :perm_a, 3, 60)

      assert :ok = SkillRateLimiter.check(key, :perm_b, 3, 60)
    end
  end
end
