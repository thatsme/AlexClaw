defmodule AlexClawWeb.DatabaseController do
  @moduledoc "Serves downloadable pg_dump database backups."

  use Phoenix.Controller, formats: [:html]
  import Plug.Conn

  def download(conn, _params) do
    db_config = db_connection_env()
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")
    filename = "alexclaw_backup_#{timestamp}.sql"

    port =
      Port.open(
        {:spawn_executable, System.find_executable("pg_dump")},
        [:binary, :exit_status, :stderr_to_stdout, args: pg_dump_args(db_config), env: [{~c"PGPASSWORD", String.to_charlist(db_config.password)}]]
      )

    conn =
      conn
      |> put_resp_content_type("application/sql")
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
      |> send_chunked(200)

    stream_port(conn, port)
  end

  defp stream_port(conn, port) do
    receive do
      {^port, {:data, chunk}} ->
        case Plug.Conn.chunk(conn, chunk) do
          {:ok, conn} -> stream_port(conn, port)
          {:error, :closed} -> conn
        end

      {^port, {:exit_status, 0}} ->
        conn

      {^port, {:exit_status, _code}} ->
        conn
    after
      60_000 ->
        Port.close(port)
        conn
    end
  end

  defp pg_dump_args(config) do
    [
      "-h", config.hostname,
      "-U", config.username,
      "-d", config.database,
      "--no-owner",
      "--no-privileges",
      "--clean",
      "--if-exists"
    ]
  end

  defp db_connection_env do
    %{
      hostname: System.get_env("DATABASE_HOSTNAME", "db"),
      username: System.get_env("DATABASE_USERNAME", "alexclaw"),
      password: System.get_env("DATABASE_PASSWORD", ""),
      database: "alex_claw_prod"
    }
  end
end
