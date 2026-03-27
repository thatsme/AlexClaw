defmodule AlexClawWeb.HealthController do
  @moduledoc "Lightweight health check for load balancers and Docker healthcheck."
  use Phoenix.Controller, formats: [:json]

  @spec check(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def check(conn, _params) do
    db_ok = db_connected?()
    status = if db_ok, do: 200, else: 503

    conn
    |> put_status(status)
    |> json(%{
      status: if(db_ok, do: "ok", else: "degraded"),
      version: to_string(Application.spec(:alex_claw, :vsn)),
      db: if(db_ok, do: "connected", else: "unreachable"),
      mcp: mcp_status()
    })
  end

  defp mcp_status do
    case Process.whereis(:"Anubis.Elixir.AlexClaw.MCP.Server.supervisor") do
      nil -> "disabled"
      pid when is_pid(pid) -> "running"
    end
  end

  defp db_connected? do
    case Ecto.Adapters.SQL.query(AlexClaw.Repo, "SELECT 1", []) do
      {:ok, _} -> true
      _ -> false
    end
  end
end
