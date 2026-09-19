defmodule AlexClawWeb.Plugs.McpAuth do
  @moduledoc """
  Bearer token authentication for the MCP endpoint.

  Checks the `Authorization: Bearer <token>` header against the
  `mcp.api_key` value stored in AlexClaw.Config. Returns 401 if
  the token is missing or invalid.
  """

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    authenticate(conn, AlexClaw.Config.get("mcp.api_key"))
  end

  defp authenticate(conn, expected_key) when expected_key in [nil, ""],
    do: send_unauthorized(conn, "MCP API key not configured")

  defp authenticate(conn, expected_key) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> verify_token(conn, token, expected_key)
      _ -> send_unauthorized(conn, "Missing Authorization header")
    end
  end

  defp verify_token(conn, token, expected_key) do
    if Plug.Crypto.secure_compare(token, expected_key) do
      conn
    else
      send_unauthorized(conn, "Invalid API key")
    end
  end

  defp send_unauthorized(conn, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: message}))
    |> halt()
  end
end
