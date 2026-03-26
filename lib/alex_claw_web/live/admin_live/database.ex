defmodule AlexClawWeb.AdminLive.Database do
  @moduledoc "LiveView page for database backup downloads, SQL restore uploads, and table inspection."

  use Phoenix.LiveView

  @max_upload_size 100_000_000

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Database",
       restoring: false,
       restore_result: nil,
       tables: list_tables()
     )
     |> allow_upload(:dump_file,
       accept: :any,
       max_entries: 1,
       max_file_size: @max_upload_size
     )}
  end

  @impl true
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("validate_upload", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("restore", _params, socket) do
    socket = assign(socket, restoring: true, restore_result: nil)

    result =
      consume_uploaded_entries(socket, :dump_file, fn %{path: path}, _entry ->
        {:ok, restore_from_file(path)}
      end)

    {status, message} =
      case result do
        [{:ok, msg}] -> {:info, msg}
        [{:error, msg}] -> {:error, msg}
        [] -> {:error, "No file uploaded"}
      end

    {:noreply,
     socket
     |> put_flash(status, message)
     |> assign(restoring: false, restore_result: message, tables: list_tables())}
  end

  @impl true
  def handle_event("refresh_tables", _, socket) do
    {:noreply, assign(socket, tables: list_tables())}
  end

  defp list_tables do
    query = """
    SELECT
      relname AS name,
      n_live_tup AS rows,
      pg_size_pretty(pg_total_relation_size(quote_ident(relname))) AS size
    FROM pg_stat_user_tables
    ORDER BY relname
    """

    case AlexClaw.Repo.query(query) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [name, rows, size] ->
          %{name: name, rows: rows, size: size}
        end)

      _ ->
        []
    end
  end

  defp restore_from_file(path) do
    db = db_connection_env()

    args = [
      "-h", db.hostname,
      "-U", db.username,
      "-d", db.database,
      "--single-transaction",
      "-f", path
    ]

    case System.cmd("psql", args, env: [{"PGPASSWORD", db.password}], stderr_to_stdout: true) do
      {output, 0} ->
        lines = String.split(output, "\n", trim: true)
        {:ok, "Restore completed (#{length(lines)} statements executed)"}

      {error, _code} ->
        {:error, "Restore failed: #{String.slice(error, 0, 500)}"}
    end
  end

  defp db_connection_env do
    %{
      hostname: System.get_env("DATABASE_HOSTNAME", "db"),
      username: System.get_env("DATABASE_USERNAME", "alexclaw"),
      password: System.get_env("DATABASE_PASSWORD", ""),
      database: "alex_claw_prod"
    }
  end

  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_size(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp upload_error_message(:too_large), do: "File too large (max 100 MB)"
  defp upload_error_message(:not_accepted), do: "Only .sql and .dump files accepted"
  defp upload_error_message(err), do: "Error: #{inspect(err)}"
end
