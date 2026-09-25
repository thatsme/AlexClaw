defmodule AlexClawWeb.Plugs.McpAuth do
  @moduledoc """
  Bearer token authentication for the MCP endpoint.

  Checks the `Authorization: Bearer <token>` header with
  `AlexClaw.MCP.Key.valid?/1`: the token's fingerprint against the stored one.
  Returns 401 if no key is set, or the token is missing or not the key.
  """

  import Plug.Conn

  alias AlexClaw.MCP.Key

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts), do: authenticate(conn, Key.fingerprint())

  defp authenticate(conn, nil), do: send_unauthorized(conn, "MCP API key not configured")

  defp authenticate(conn, _fingerprint) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> verify_token(conn, Key.valid?(token))
      _ -> send_unauthorized(conn, "Missing Authorization header")
    end
  end

  defp verify_token(conn, true), do: conn
  defp verify_token(conn, false), do: send_unauthorized(conn, "Invalid API key")

  defp send_unauthorized(conn, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: message}))
    |> halt()
  end
end
