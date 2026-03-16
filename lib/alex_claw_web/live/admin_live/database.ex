defmodule AlexClawWeb.AdminLive.Database do
  @moduledoc "LiveView page for database backup downloads, SQL restore uploads, and table inspection."

  use Phoenix.LiveView

  @max_upload_size 100_000_000

  @impl true
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

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-8">
      <h1 class="text-2xl font-bold text-white">Database</h1>

      <div class="bg-gray-900 rounded-lg border border-gray-800 p-6">
        <h2 class="text-lg font-semibold text-gray-300 mb-2">Backup</h2>
        <p class="text-sm text-gray-500 mb-4">Create a full database dump (pg_dump) and download it as a .sql file.</p>
        <a href="/database/download" class="inline-block px-4 py-2 bg-claw-700 hover:bg-claw-600 text-white text-sm rounded transition">
          Download Backup
        </a>
      </div>

      <div class="bg-gray-900 rounded-lg border border-gray-800 p-6">
        <h2 class="text-lg font-semibold text-gray-300 mb-2">Restore</h2>
        <p class="text-sm text-gray-500 mb-4">Upload a .sql dump file to restore the database. This will replace existing data.</p>

        <form phx-submit="restore" phx-change="validate_upload" class="space-y-4">
          <div class="flex items-center space-x-4">
            <label class="flex-1">
              <div class="relative">
                <.live_file_input upload={@uploads.dump_file}
                  class="block w-full text-sm text-gray-400
                    file:mr-4 file:py-2 file:px-4 file:rounded
                    file:border-0 file:text-sm file:font-semibold
                    file:bg-gray-800 file:text-gray-300
                    hover:file:bg-gray-700 file:cursor-pointer" />
              </div>
            </label>
          </div>

          <%= for entry <- @uploads.dump_file.entries do %>
            <div class="flex items-center space-x-3 text-sm">
              <span class="text-gray-300">{entry.client_name}</span>
              <span class="text-gray-500">({format_size(entry.client_size)})</span>
              <button type="button" phx-click="cancel-upload" phx-value-ref={entry.ref}
                class="text-red-500 hover:text-red-400 text-xs">&times;</button>
            </div>
            <%= for err <- upload_errors(@uploads.dump_file, entry) do %>
              <p class="text-red-400 text-sm">{upload_error_message(err)}</p>
            <% end %>
          <% end %>

          <div class="flex items-center space-x-3">
            <button type="submit"
              disabled={@uploads.dump_file.entries == [] || @restoring}
              class={[
                "px-4 py-2 text-white text-sm rounded transition",
                if(@uploads.dump_file.entries == [] || @restoring,
                  do: "bg-gray-700 cursor-not-allowed",
                  else: "bg-red-700 hover:bg-red-600")
              ]}>
              {if @restoring, do: "Restoring...", else: "Restore Database"}
            </button>
            <span :if={@restoring} class="text-yellow-400 text-sm animate-pulse">Processing, please wait...</span>
          </div>
        </form>
      </div>

      <div class="bg-gray-900 rounded-lg border border-gray-800 overflow-hidden">
        <div class="flex justify-between items-center px-4 py-3 bg-gray-800">
          <h2 class="text-lg font-semibold text-gray-300">Tables</h2>
          <button phx-click="refresh_tables" class="text-xs text-claw-500 hover:text-claw-400">Refresh</button>
        </div>
        <table class="w-full">
          <thead class="bg-gray-800/50">
            <tr>
              <th class="px-4 py-2 text-left text-xs text-gray-400 uppercase">Table</th>
              <th class="px-4 py-2 text-right text-xs text-gray-400 uppercase">Rows</th>
              <th class="px-4 py-2 text-right text-xs text-gray-400 uppercase">Size</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={table <- @tables} class="border-t border-gray-800">
              <td class="px-4 py-2 text-sm font-mono text-white">{table.name}</td>
              <td class="px-4 py-2 text-sm text-gray-400 text-right font-mono">{table.rows}</td>
              <td class="px-4 py-2 text-sm text-gray-500 text-right">{table.size}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
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
