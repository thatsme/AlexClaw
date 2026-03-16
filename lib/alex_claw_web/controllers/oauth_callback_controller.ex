defmodule AlexClawWeb.OAuthCallbackController do
  @moduledoc "Handles OAuth2 redirect callbacks for Google Calendar integration."

  use Phoenix.Controller, formats: [:html]
  import Plug.Conn

  alias AlexClaw.Google.OAuth
  alias AlexClaw.Gateway

  def google(conn, %{"code" => code, "state" => state}) do
    case OAuth.handle_callback(code, state) do
      {:ok, chat_id} ->
        Gateway.send_html(
          "<b>Google Calendar connected!</b>\n\nYour calendar events are now available in workflows.\nUse the <code>google_calendar</code> skill in a workflow step.",
          chat_id: parse_chat_id(chat_id)
        )

        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, success_html())

      {:error, :state_expired} ->
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(400, error_html("Link expired. Send /connect google again."))

      {:error, :invalid_state} ->
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(400, error_html("Invalid or already used link. Send /connect google again."))

      {:error, :no_refresh_token} ->
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(400, error_html("Google did not return a refresh token. Try /connect google again — Google needs to show the consent screen."))

      {:error, reason} ->
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(500, error_html("Connection failed: #{inspect(reason)}"))
    end
  end

  def google(conn, %{"error" => error}) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(400, error_html("Authorization denied: #{error}"))
  end

  defp parse_chat_id(id) when is_integer(id), do: id
  defp parse_chat_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, _} -> int
      :error -> id
    end
  end
  defp parse_chat_id(id), do: id

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
