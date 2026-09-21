defmodule AlexClawWeb.Live.RequireSession do
  @moduledoc """
  The `on_mount` hook of every authenticated LiveView.

  A LiveView's session is a copy signed into the page when it was rendered,
  and it outlives logout. So the hook does not trust what the copy says about
  being signed in: it takes the login's sid from it and asks
  `AlexClaw.Auth.Sessions`, which knows whether that login still stands.
  """
  import Phoenix.LiveView, only: [redirect: 2]

  alias AlexClaw.Auth.Sessions

  @spec on_mount(:default, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont | :halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, _params, session, socket) do
    admit(Sessions.valid?(session["elevation_sid"]), socket)
  end

  defp admit(true, socket), do: {:cont, socket}
  defp admit(false, socket), do: {:halt, redirect(socket, to: "/login")}
end
