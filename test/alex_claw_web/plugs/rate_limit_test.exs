defmodule AlexClawWeb.Plugs.RateLimitTest do
  use AlexClawWeb.ConnCase, async: false
  @moduletag :integration

  describe "call/2" do
    test "passes through GET requests" do
      conn = get(build_conn(), "/login")
      refute conn.halted
    end

    test "passes through non-login POST requests" do
      conn = post(build_conn(), "/health")
      # Should not be rate-limited (different path)
      refute conn.status == 429
    end

    test "allows POST /login when not rate limited" do
      conn = post(build_conn(), "/login", %{password: "wrong"})
      refute conn.status == 429
    end
  end

  describe "get_client_ip/1" do
    test "extracts IP from conn" do
      conn = build_conn()
      ip = AlexClawWeb.Plugs.RateLimit.get_client_ip(conn)
      assert is_binary(ip)
    end
  end
end
