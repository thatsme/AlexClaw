defmodule AlexClawWeb.Plugs.RequireAuth do
  @moduledoc """
  Plug that requires session-based authentication.
  Redirects unauthenticated requests to the login page.
  Sessions expire after a configurable max age (default 8 hours).
  """
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  # 8 hours in seconds
  @max_session_age 8 * 60 * 60

  def init(opts), do: opts

  def call(conn, _opts) do
    authenticated = get_session(conn, :authenticated)
    authenticated_at = get_session(conn, :authenticated_at)

    cond do
      !authenticated ->
        redirect_to_login(conn)

      session_expired?(authenticated_at) ->
        conn
        |> clear_session()
        |> redirect_to_login()

      true ->
        conn
    end
  end

  defp session_expired?(nil), do: true

  defp session_expired?(authenticated_at) do
    System.system_time(:second) - authenticated_at > @max_session_age
  end

  defp redirect_to_login(conn) do
    conn
    |> redirect(to: "/login")
    |> halt()
  end
end
