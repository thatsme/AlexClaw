defmodule AlexClawWeb.Plugs.McpForward do
  @moduledoc """
  Runtime forwarder to the Anubis MCP StreamableHTTP Plug.

  Defers Plug.init until the first request, avoiding the persistent_term
  issue where Anubis.Server.Supervisor hasn't stored the session config
  yet at Phoenix route compile time.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    plug_opts = Anubis.Server.Transport.StreamableHTTP.Plug.init(server: AlexClaw.MCP.Server)
    Anubis.Server.Transport.StreamableHTTP.Plug.call(conn, plug_opts)
  end
end
