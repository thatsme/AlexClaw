defmodule AlexClawWeb.Plugs.McpAuthTest do
  use AlexClawWeb.ConnCase, async: false

  alias AlexClawWeb.Plugs.McpAuth

  setup do
    AlexClaw.Config.set("mcp.api_key", "test-mcp-key-2026", type: "string", category: "mcp")
    :ok
  end

  describe "call/2" do
    test "passes through with valid Bearer token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer test-mcp-key-2026")
        |> McpAuth.call([])

      refute conn.halted
    end

    test "returns 401 with missing Authorization header", %{conn: conn} do
      conn = McpAuth.call(conn, [])

      assert conn.halted
      assert conn.status == 401
      body = Jason.decode!(conn.resp_body)
      assert body["error"] =~ "Missing"
    end

    test "returns 401 with invalid token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer wrong-key")
        |> McpAuth.call([])

      assert conn.halted
      assert conn.status == 401
      body = Jason.decode!(conn.resp_body)
      assert body["error"] =~ "Invalid"
    end

    test "returns 401 with non-Bearer auth scheme", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Basic dXNlcjpwYXNz")
        |> McpAuth.call([])

      assert conn.halted
      assert conn.status == 401
    end

    test "returns 401 when api_key is not configured", %{conn: conn} do
      AlexClaw.Config.delete("mcp.api_key")

      conn =
        conn
        |> put_req_header("authorization", "Bearer some-key")
        |> McpAuth.call([])

      assert conn.halted
      assert conn.status == 401
      body = Jason.decode!(conn.resp_body)
      assert body["error"] =~ "not configured"
    end

    test "returns JSON content-type on error", %{conn: conn} do
      conn = McpAuth.call(conn, [])

      assert {"content-type", content_type} =
               List.keyfind(conn.resp_headers, "content-type", 0)

      assert content_type =~ "application/json"
    end
  end
end
