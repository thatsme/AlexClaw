defmodule AlexClawWeb.Plugs.CachingBodyReader do
  @moduledoc """
  Custom body reader that caches the raw request body for HMAC verification.
  Used as the `body_reader` option on `Plug.Parsers` in the endpoint so that
  the original bytes are available after JSON parsing.
  Enforces a 1 MB max body size to prevent memory exhaustion.
  """

  # 1 MB max body size
  @max_body_size 1_048_576

  @spec read_body(Plug.Conn.t(), keyword()) :: {:ok, binary(), Plug.Conn.t()} | {:more, binary(), Plug.Conn.t()} | {:error, term()}
  def read_body(conn, opts) do
    opts = Keyword.put_new(opts, :length, @max_body_size)

    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        conn = update_in(conn.assigns[:raw_body], &((&1 || "") <> body))
        {:ok, body, conn}

      {:more, body, conn} ->
        accumulated = (conn.assigns[:raw_body] || "") <> body

        if byte_size(accumulated) > @max_body_size do
          {:error, :too_large}
        else
          conn = put_in(conn.assigns[:raw_body], accumulated)
          {:more, body, conn}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
