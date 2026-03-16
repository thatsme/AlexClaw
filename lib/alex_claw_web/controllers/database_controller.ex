defmodule AlexClawWeb.DatabaseController do
  @moduledoc "Serves downloadable pg_dump database backups."

  use Phoenix.Controller, formats: [:html]
  import Plug.Conn

  def download(conn, _params) do
    db_config = db_connection_env()

    case System.cmd("pg_dump", pg_dump_args(db_config), env: [{"PGPASSWORD", db_config.password}], stderr_to_stdout: true) do
      {dump, 0} ->
        timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")
        filename = "alexclaw_backup_#{timestamp}.sql"

        conn
        |> put_resp_content_type("application/sql")
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
        |> send_resp(200, dump)

      {error, _code} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(500, "pg_dump failed: #{error}")
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
