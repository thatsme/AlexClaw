defmodule AlexClawWeb.SecurityHardeningTest do
  use AlexClawWeb.ConnCase, async: false

  alias AlexClaw.Config

  describe "session expiration" do
    test "redirects to login when session has no authenticated_at timestamp", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:authenticated, true)
        # no :authenticated_at — simulates pre-hardening session
        |> get("/")

      assert redirected_to(conn) == "/login"
    end

    test "redirects to login when session is older than 8 hours", %{conn: conn} do
      nine_hours_ago = System.system_time(:second) - 9 * 60 * 60

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:authenticated, true)
        |> put_session(:authenticated_at, nine_hours_ago)
        |> get("/")

      assert redirected_to(conn) == "/login"
    end

    test "allows access when session is fresh", %{conn: conn} do
      conn = conn |> authenticate() |> get("/metrics")
      assert conn.status == 200
    end

    test "clears session on expiration", %{conn: conn} do
      expired_at = System.system_time(:second) - 9 * 60 * 60

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:authenticated, true)
        |> put_session(:authenticated_at, expired_at)
        |> get("/")

      assert redirected_to(conn) == "/login"
      # Session should be cleared — follow redirect and verify no access
      conn = get(recycle(conn), "/metrics")
      assert redirected_to(conn) == "/login"
    end
  end

  describe "logout requires POST" do
    test "POST /logout clears session and redirects to login", %{conn: conn} do
      conn =
        conn
        |> authenticate()
        |> post("/logout")

      assert redirected_to(conn) == "/login"
      # Session should be cleared
      conn = get(recycle(conn), "/metrics")
      assert redirected_to(conn) == "/login"
    end

    test "GET /logout is not routed (no GET route)", %{conn: conn} do
      conn =
        conn
        |> authenticate()
        |> get("/logout")

      # Phoenix returns 404 for unmatched routes
      assert conn.status in [404, 405]
    end
  end

  describe "X-Forwarded-For trust" do
    test "ignores X-Forwarded-For by default", %{conn: conn} do
      Config.set("auth.trust_proxy_headers", "false", type: "boolean", category: "auth")

      ip = AlexClawWeb.Plugs.RateLimit.get_client_ip(%{conn | remote_ip: {10, 0, 0, 1}})
      assert ip == "10.0.0.1"

      spoofed =
        conn
        |> put_req_header("x-forwarded-for", "1.2.3.4")
        |> Map.put(:remote_ip, {10, 0, 0, 1})

      ip = AlexClawWeb.Plugs.RateLimit.get_client_ip(spoofed)
      assert ip == "10.0.0.1"
    end

    test "trusts X-Forwarded-For when auth.trust_proxy_headers is enabled", %{conn: conn} do
      Config.set("auth.trust_proxy_headers", "true", type: "boolean", category: "auth")

      spoofed =
        conn
        |> put_req_header("x-forwarded-for", "1.2.3.4, 10.0.0.1")
        |> Map.put(:remote_ip, {10, 0, 0, 1})

      ip = AlexClawWeb.Plugs.RateLimit.get_client_ip(spoofed)
      assert ip == "1.2.3.4"
    end

    test "falls back to remote_ip when trust enabled but no header", %{conn: conn} do
      Config.set("auth.trust_proxy_headers", "true", type: "boolean", category: "auth")

      ip = AlexClawWeb.Plugs.RateLimit.get_client_ip(%{conn | remote_ip: {192, 168, 1, 1}})
      assert ip == "192.168.1.1"
    end
  end

  describe "CachingBodyReader size limit" do
    test "rejects oversized request body", %{conn: conn} do
      # 2 MB JSON payload — exceeds the 1 MB limit
      padding = String.duplicate("x", 2 * 1_048_576)
      large_body = Jason.encode!(%{"data" => padding})

      assert_raise Plug.Parsers.RequestTooLargeError, fn ->
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/webhooks/github", large_body)
      end
    end
  end
end
