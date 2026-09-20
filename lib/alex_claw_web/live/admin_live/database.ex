defmodule AlexClawWeb.AdminLive.Database do
  @moduledoc "LiveView page for database backup downloads, SQL restore uploads, and table inspection."

  use Phoenix.LiveView

  alias AlexClaw.Auth.{Elevation, Gate}
  alias AlexClaw.Database.Restore

  @max_upload_size 100_000_000

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, session, socket) do
    socket = AlexClawWeb.Live.Elevation.assign_elevation(socket, session)

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
  def handle_info({:elevation, _state, _detail} = message, socket) do
    {:noreply, AlexClawWeb.Live.Elevation.handle_broadcast(socket, message)}
  end

  @impl true
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("validate_upload", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  # A restore is arbitrary SQL against the live database, so it is challenged
  # every time rather than covered by an elevation window. An unlock earned for
  # editing a setting is not authority to replace the database.
  def handle_event("restore", _params, socket) do
    socket
    |> consume_uploaded_entries(:dump_file, fn %{path: path}, entry ->
      {:ok, {Restore.stage(path), entry.client_name}}
    end)
    |> staged(socket)
  end

  @impl true
  def handle_event("refresh_tables", _, socket) do
    {:noreply, assign(socket, tables: list_tables())}
  end

  defp staged([{{:ok, path}, filename}], socket) do
    challenge(Elevation.required?(), path, filename, socket)
  end

  defp staged([{{:error, reason}, _filename}], socket) do
    {:noreply, put_flash(socket, :error, "Could not stage the upload: #{inspect(reason)}")}
  end

  defp staged([], socket), do: {:noreply, put_flash(socket, :error, "No file uploaded")}

  # Nothing to verify on an instance without a second factor: the restore is
  # protected by the admin password, exactly as the banner says.
  defp challenge(false, path, filename, socket) do
    AlexClawWeb.Live.Elevation.audit_unprotected(socket, "database restore from #{filename}")

    {:noreply,
     socket
     |> assign(restore_result: nil)
     |> restored(Restore.run(path))}
  end

  defp challenge(true, path, filename, socket) do
    %{type: :database_restore, path: path, filename: filename}
    |> Gate.request("Restore the database from *#{filename}* — this replaces live data")
    |> requested(path, socket)
  end

  defp requested(:challenged, _path, socket) do
    {:noreply,
     put_flash(socket, :info, "2FA code requested — the restore runs once you answer it")}
  end

  defp requested(:no_2fa, path, socket) do
    Restore.discard(path)

    {:noreply,
     put_flash(
       socket,
       :error,
       "A restore needs a second factor, and no gateway is configured to ask for one"
     )}
  end

  defp restored(socket, {:ok, message}) do
    socket
    |> put_flash(:info, message)
    |> assign(restoring: false, restore_result: message, tables: list_tables())
  end

  defp restored(socket, {:error, message}) do
    socket
    |> put_flash(:error, message)
    |> assign(restoring: false, restore_result: message)
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

  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_size(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp upload_error_message(:too_large), do: "File too large (max 100 MB)"
  defp upload_error_message(:not_accepted), do: "Only .sql and .dump files accepted"
  defp upload_error_message(err), do: "Error: #{inspect(err)}"
end
