defmodule AlexClaw.RateLimiterTest do
  use ExUnit.Case, async: false

  alias AlexClaw.RateLimiter

  setup do
    RateLimiter.clear("test_ip_#{System.unique_integer([:positive])}")
    :ok
  end

  describe "check/1" do
    test "returns :ok for unknown IP" do
      assert :ok = RateLimiter.check("192.168.1.#{System.unique_integer([:positive])}")
    end
  end

  describe "record_failure/1" do
    test "records without crashing" do
      ip = "10.0.0.#{System.unique_integer([:positive])}"
      assert :ok = RateLimiter.record_failure(ip)
    end
  end

  describe "clear/1" do
    test "clears a specific IP" do
      ip = "10.0.0.#{System.unique_integer([:positive])}"
      RateLimiter.record_failure(ip)
      RateLimiter.clear(ip)
      assert :ok = RateLimiter.check(ip)
    end
  end
end
