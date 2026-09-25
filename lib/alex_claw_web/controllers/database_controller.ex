defmodule AlexClawWeb.DatabaseController do
  @moduledoc """
  Serves the database as a download: the full `pg_dump` script, and the data
  export a restore reads. Each needs the session's elevation and is audited
  (`AlexClaw.ControlPlane.perform/3`); without it the answer is 403.
  """

  use Phoenix.Controller, formats: [:html]
  import Plug.Conn

  alias AlexClaw.ControlPlane
  alias AlexClaw.ControlPlane.Context

  @spec download(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def download(conn, _params) do
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")

    :download_database
    |> ControlPlane.perform(
      %{
        acc: conn,
        open: &open(&1, "application/sql", "alexclaw_backup_#{timestamp}.sql"),
        emit: &dumped/2,
        detail: "full database dump"
      },
      context(conn)
    )
    |> served(conn)
  end

  @doc """
  The application's data as a restore file: JSON values, never SQL — see
  `AlexClaw.Database.DataExport`. Streamed, so it is never held whole.
  """
  @spec export(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def export(conn, _params) do
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")

    :export_data
    |> ControlPlane.perform(
      %{
        acc: conn,
        open: &open(&1, "application/json", "alexclaw_data_#{timestamp}.json"),
        emit: &exported/2,
        detail: "data export"
      },
      context(conn)
    )
    |> served(conn)
  end

  defp context(conn), do: Context.admin_ui(get_session(conn, :elevation_sid))

  # The response starts only once the download is allowed and audited.
  defp open(conn, content_type, filename) do
    conn
    |> put_resp_content_type(content_type)
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
    |> send_chunked(200)
  end

  defp dumped(data, conn), do: chunk(conn, data)

  defp exported(data, conn) do
    {:ok, conn} = chunk(conn, data)
    conn
  end

  defp served({:ok, conn}, _conn), do: conn
  defp served({:error, reason}, conn), do: refused(conn, reason)

  @doc "The answer to a download `AlexClaw.ControlPlane.perform/3` refused: 403, and why."
  @spec refused(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def refused(conn, reason) do
    conn
    |> put_status(403)
    |> text("Not allowed: #{refusal(reason)}")
  end

  defp refusal(:second_factor_required), do: "unlock editing first"
  defp refusal(reason), do: inspect(reason)
end
