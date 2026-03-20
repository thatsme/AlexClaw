defmodule AlexClawWeb.Plugs.RateLimit do
  @moduledoc """
  Plug that enforces login rate limiting.
  Only applies to POST /login. GET requests pass through.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(%Plug.Conn{method: "POST", request_path: "/login"} = conn, _opts) do
    ip = get_client_ip(conn)

    case AlexClaw.RateLimiter.check(ip) do
      :ok ->
        conn

      {:error, :rate_limited, seconds_remaining} ->
        minutes = ceil(seconds_remaining / 60)

        conn
        |> put_resp_content_type("text/html")
        |> send_resp(429, rate_limit_html(minutes))
        |> halt()
    end
  end

  def call(conn, _opts), do: conn

  @doc """
  Extract client IP. Only trusts X-Forwarded-For when `auth.trust_proxy_headers`
  is enabled in config (for deployments behind a reverse proxy).
  """
  def get_client_ip(conn) do
    if AlexClaw.Config.get("auth.trust_proxy_headers") == true do
      forwarded = get_req_header(conn, "x-forwarded-for") |> List.first()

      if forwarded && forwarded != "" do
        forwarded |> String.split(",") |> List.first() |> String.trim()
      else
        conn.remote_ip |> :inet.ntoa() |> to_string()
      end
    else
      conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end

  defp rate_limit_html(minutes) do
    """
    <!DOCTYPE html>
    <html lang="en" class="dark">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <title>AlexClaw - Rate Limited</title>
      <script src="https://cdn.tailwindcss.com"></script>
      <script>
        tailwind.config = {
          darkMode: 'class',
          theme: { extend: { colors: { claw: { 500: '#0ea5e9', 700: '#0369a1' } } } }
        }
      </script>
    </head>
    <body class="bg-gray-950 text-gray-100 min-h-screen flex items-center justify-center">
      <div class="w-full max-w-sm">
        <div class="bg-gray-900 rounded-lg border border-gray-800 p-8 text-center">
          <h1 class="text-2xl font-bold text-claw-500 mb-4">AlexClaw</h1>
          <p class="text-red-400 text-sm mb-4">Too many failed attempts.</p>
          <p class="text-gray-400 text-sm">Try again in #{minutes} minute(s).</p>
        </div>
      </div>
    </body>
    </html>
    """
  end
end
