defmodule AlexClawWeb.Plugs.RequireAuth do
  @moduledoc """
  Plug that requires a live admin login.

  Whether the login stands is decided by `AlexClaw.Auth.Sessions` on the
  server — opened at login, closed at logout, eight hours at most — never by
  what the session cookie says about itself. LiveView mounts ask the same
  question through `AlexClawWeb.Live.RequireSession`.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  alias AlexClaw.Auth.Sessions

  def init(opts), do: opts

  def call(conn, _opts), do: admit(Sessions.valid?(get_session(conn, :elevation_sid)), conn)

  defp admit(true, conn), do: conn

  defp admit(false, conn) do
    conn
    |> clear_session()
    |> redirect(to: "/login")
    |> halt()
  end
end
