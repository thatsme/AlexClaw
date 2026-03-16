defmodule AlexClawWeb.Plugs.CachingBodyReader do
  @moduledoc """
  Custom body reader that caches the raw request body for HMAC verification.
  Used as the `body_reader` option on `Plug.Parsers` in the endpoint so that
  the original bytes are available after JSON parsing.
  """

  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        conn = update_in(conn.assigns[:raw_body], &((&1 || "") <> body))
        {:ok, body, conn}

      {:more, body, conn} ->
        conn = update_in(conn.assigns[:raw_body], &((&1 || "") <> body))
        {:more, body, conn}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
