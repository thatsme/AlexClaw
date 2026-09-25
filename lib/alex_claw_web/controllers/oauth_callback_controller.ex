defmodule AlexClawWeb.OAuthCallbackController do
  @moduledoc """
  The Google OAuth redirect. It needs the signed-in session that asked for
  the connection, holding the elevation: the state must have been issued to
  that session, and the exchange is performed as `:connect_google` through
  `AlexClaw.ControlPlane.perform/3`.
  """

  use Phoenix.Controller, formats: [:html]
  import Plug.Conn

  alias AlexClaw.Auth.Elevation
  alias AlexClaw.ControlPlane
  alias AlexClaw.ControlPlane.Context

  @again "Connect Google again from the admin UI (Services page)."

  @spec google(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def google(conn, %{"code" => code, "state" => state}) do
    sid = get_session(conn, :elevation_sid)

    :connect_google
    |> ControlPlane.perform(
      %{step: :finish, code: code, state: state, owner: owner(sid)},
      Context.admin_ui(sid)
    )
    |> answered(conn)
  end

  def google(conn, %{"error" => error}) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(400, error_html("Authorization denied: #{error}"))
  end

  defp owner(sid) when is_binary(sid), do: Elevation.fingerprint(sid)
  defp owner(_sid), do: "unidentified"

  defp answered({:ok, _owner}, conn), do: page(conn, 200, success_html())

  defp answered({:error, :second_factor_required}, conn),
    do: page(conn, 403, error_html("Unlock editing in the admin UI first, then " <> @again))

  defp answered({:error, :state_expired}, conn),
    do: page(conn, 400, error_html("Link expired. " <> @again))

  defp answered({:error, :invalid_state}, conn),
    do: page(conn, 400, error_html("Invalid or already used link. " <> @again))

  defp answered({:error, :no_refresh_token}, conn) do
    page(
      conn,
      400,
      error_html(
        "Google did not return a refresh token — Google needs to show the consent screen. " <>
          @again
      )
    )
  end

  defp answered({:error, reason}, conn),
    do: page(conn, 500, error_html("Connection failed: #{inspect(reason)}"))

  defp page(conn, status, html) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(status, html)
  end

  defp success_html do
    """
    <!DOCTYPE html>
    <html><head><title>AlexClaw</title>
    <style>body{font-family:system-ui;background:#111;color:#fff;display:flex;justify-content:center;align-items:center;height:100vh;margin:0}
    .card{text-align:center;padding:2rem;border:1px solid #333;border-radius:8px;max-width:400px}
    h1{color:#4ade80}p{color:#9ca3af}</style></head>
    <body><div class="card"><h1>Connected!</h1><p>Google Calendar is now linked to AlexClaw.<br>You can close this tab.</p></div></body></html>
    """
  end

  defp error_html(message) do
    safe_message =
      message
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")
      |> String.replace("\"", "&quot;")

    """
    <!DOCTYPE html>
    <html><head><title>AlexClaw</title>
    <style>body{font-family:system-ui;background:#111;color:#fff;display:flex;justify-content:center;align-items:center;height:100vh;margin:0}
    .card{text-align:center;padding:2rem;border:1px solid #333;border-radius:8px;max-width:400px}
    h1{color:#ef4444}p{color:#9ca3af}</style></head>
    <body><div class="card"><h1>Error</h1><p>#{safe_message}</p></div></body></html>
    """
  end
end
