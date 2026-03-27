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
    expected_key = AlexClaw.Config.get("mcp.api_key")

    if is_nil(expected_key) or expected_key == "" do
      send_unauthorized(conn, "MCP API key not configured")
    else
      case get_req_header(conn, "authorization") do
        ["Bearer " <> token] ->
          if Plug.Crypto.secure_compare(token, expected_key) do
            conn
          else
            send_unauthorized(conn, "Invalid API key")
          end

        _ ->
          send_unauthorized(conn, "Missing Authorization header")
      end
    end
  end

  defp send_unauthorized(conn, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: message}))
    |> halt()
  end
end
