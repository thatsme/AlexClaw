defmodule AlexClawWeb.Plugs.McpForward do
  @moduledoc """
  Runtime forwarder to the Anubis MCP StreamableHTTP Plug.

  Defers the transport plug's init until the first request, avoiding the
  persistent_term issue where Anubis.Server.Supervisor hasn't stored the
  session config yet at Phoenix route compile time.
  """

  @behaviour Plug

  alias Anubis.Server.Transport.StreamableHTTP

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    plug_opts = StreamableHTTP.Plug.init(server: AlexClaw.MCP.Server)
    StreamableHTTP.Plug.call(conn, plug_opts)
  end
end
