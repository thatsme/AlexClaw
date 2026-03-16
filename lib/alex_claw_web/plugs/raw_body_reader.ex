defmodule AlexClawWeb.Plugs.RawBodyReader do
  @moduledoc """
  Reads and caches the raw request body before JSON parsing.
  Required for GitHub webhook HMAC-SHA256 signature verification.
  Must be in the webhook pipeline before the JSON parser runs.
  """
  @behaviour Plug

  def init(opts), do: opts

  def call(conn, _opts) do
    case Plug.Conn.read_body(conn) do
      {:ok, body, conn} -> Plug.Conn.assign(conn, :raw_body, body)
      {:more, partial, conn} -> read_full_body(conn, partial)
      {:error, _} -> conn
    end
  end

  defp read_full_body(conn, acc) do
    case Plug.Conn.read_body(conn) do
      {:ok, chunk, conn} -> Plug.Conn.assign(conn, :raw_body, acc <> chunk)
      {:more, chunk, conn} -> read_full_body(conn, acc <> chunk)
      {:error, _} -> Plug.Conn.assign(conn, :raw_body, acc)
    end
  end
end
