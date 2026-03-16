defmodule AlexClawWeb.Plugs.RequireAuth do
  @moduledoc """
  Plug that requires session-based authentication.
  Redirects unauthenticated requests to the login page.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  def init(opts), do: opts

  def call(conn, _opts) do
    if get_session(conn, :authenticated) do
      conn
    else
      conn
      |> redirect(to: "/login")
      |> halt()
    end
  end
end
