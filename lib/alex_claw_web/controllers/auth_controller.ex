defmodule AlexClawWeb.AuthController do
  @moduledoc "Handles password-based admin login, logout, and session management."

  use Phoenix.Controller, formats: [:html]
  import Plug.Conn

  plug :put_root_layout, html: {AlexClawWeb.Layouts, :root}
  plug :put_layout, false

  def login(conn, _params) do
    if get_session(conn, :authenticated) do
      redirect(conn, to: "/")
    else
      conn
      |> put_resp_content_type("text/html")
      |> send_resp(200, render_login(nil))
    end
  end

  def authenticate(conn, %{"password" => password}) do
    admin_password = Application.get_env(:alex_claw, :admin_password)
    ip = AlexClawWeb.Plugs.RateLimit.get_client_ip(conn)

    cond do
      is_nil(admin_password) or admin_password == "" ->
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(401, render_login("ADMIN_PASSWORD is not set. Set it in your .env file and restart."))

      Plug.Crypto.secure_compare(password, admin_password) ->
        AlexClaw.RateLimiter.clear(ip)
        conn
        |> put_session(:authenticated, true)
        |> redirect(to: "/")

      true ->
        AlexClaw.RateLimiter.record_failure(ip)
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(401, render_login("Invalid password"))
    end
  end

  def logout(conn, _params) do
    conn
    |> clear_session()
    |> redirect(to: "/login")
  end

  defp escape_html(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp render_login(error) do
    error_html =
      if error,
        do: ~s|<p class="text-red-400 text-sm mb-4">#{escape_html(error)}</p>|,
        else: ""

    """
    <!DOCTYPE html>
    <html lang="en" class="dark">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <title>AlexClaw - Login</title>
      <script src="https://cdn.tailwindcss.com"></script>
      <script>
        tailwind.config = {
          darkMode: 'class',
          theme: {
            extend: {
              colors: {
                claw: { 500: '#0ea5e9', 600: '#0284c7', 700: '#0369a1' }
              }
            }
          }
        }
      </script>
    </head>
    <body class="bg-gray-950 text-gray-100 min-h-screen flex items-center justify-center">
      <div class="w-full max-w-sm">
        <div class="bg-gray-900 rounded-lg border border-gray-800 p-8">
          <h1 class="text-2xl font-bold text-claw-500 text-center mb-6">AlexClaw</h1>
          #{error_html}
          <form method="post" action="/login" class="space-y-4">
            <input type="hidden" name="_csrf_token" value="#{Plug.CSRFProtection.get_csrf_token()}" />
            <div>
              <label class="block text-sm text-gray-400 mb-1">Password</label>
              <input type="password" name="password" required autofocus
                class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-2 text-white text-sm focus:border-claw-500 focus:outline-none" />
            </div>
            <button type="submit"
              class="w-full px-4 py-2 bg-claw-700 hover:bg-claw-600 text-white text-sm rounded transition">
              Sign In
            </button>
          </form>
        </div>
      </div>
    </body>
    </html>
    """
  end
end
