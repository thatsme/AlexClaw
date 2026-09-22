defmodule AlexClawWeb.Plugs.McpForwardTest do
  @moduledoc """
  An authenticated request to /mcp reaches the MCP server. The forwarder once
  called Plug.init/1 — core Plug, not the transport, after its alias ended up
  inside the moduledoc — so every authenticated request was a 500 while the
  401s for unauthenticated ones kept looking healthy.
  """
  use AlexClawWeb.ConnCase, async: false
  @moduletag :integration

  setup do
    AlexClaw.Config.set("mcp.api_key", "test-mcp-key-2026", type: "string", category: "mcp")
    :ok
  end

  @initialize %{
    "jsonrpc" => "2.0",
    "id" => 1,
    "method" => "initialize",
    "params" => %{
      "protocolVersion" => "2025-03-26",
      "capabilities" => %{},
      "clientInfo" => %{"name" => "test", "version" => "0"}
    }
  }

  test "an authenticated initialize is answered by the MCP server", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer test-mcp-key-2026")
      |> put_req_header("content-type", "application/json")
      # JSON only: with text/event-stream the transport answers as a stream.
      |> put_req_header("accept", "application/json")
      |> post("/mcp", Jason.encode!(@initialize))

    assert conn.status == 200
    assert conn.resp_body =~ ~s("serverInfo")
    assert conn.resp_body =~ ~s("alexclaw")
  end

  test "an unauthenticated request never reaches it", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", Jason.encode!(@initialize))

    assert conn.status == 401
  end
end
