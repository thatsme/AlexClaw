defmodule AlexClawWeb.Plugs.RawBodyReader do
  @moduledoc """
  Reads and caches the raw request body before JSON parsing.
  Required for GitHub webhook HMAC-SHA256 signature verification.
  Must be in the webhook pipeline before the JSON parser runs.
  Enforces a 1 MB size limit to prevent memory exhaustion.
  """
  @behaviour Plug

  # 1 MB max body size for webhooks
  @max_body_size 1_048_576

  def init(opts), do: opts

  def call(conn, _opts) do
    case Plug.Conn.read_body(conn, length: @max_body_size) do
      {:ok, body, conn} ->
        Plug.Conn.assign(conn, :raw_body, body)

      {:more, _partial, conn} ->
        conn
        |> Plug.Conn.send_resp(413, "Request body too large")
        |> Plug.Conn.halt()

      {:error, _} ->
        conn
    end
  end
end
