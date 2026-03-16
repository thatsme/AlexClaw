defmodule AlexClawWeb.Endpoint do
  @moduledoc "Phoenix endpoint that configures the HTTP listener, session, and plug pipeline."

  use Phoenix.Endpoint, otp_app: :alex_claw

  @session_options [
    store: :cookie,
    key: "_alex_claw_key",
    signing_salt: "k8Xq3mN7vR2p",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  plug Plug.Static,
    at: "/",
    from: :alex_claw,
    gzip: false,
    only: ~w(assets)

  plug Plug.RequestId
  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library(),
    body_reader: {AlexClawWeb.Plugs.CachingBodyReader, :read_body, []}

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug AlexClawWeb.Router
end
