defmodule AlexClawWeb.AdminLive.Database do
  @moduledoc "LiveView page for database backups, data exports, data restores and table inspection."

  use Phoenix.LiveView

  alias AlexClaw.Auth.Elevation
  alias AlexClaw.Database.Restore
  alias AlexClawWeb.Live.ActionCode

  @max_upload_size 100_000_000

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(AlexClaw.PubSub, "database:restore")

    socket =
      socket
      |> AlexClawWeb.Live.Elevation.assign_elevation(session)
      |> ActionCode.assign_action_code()

    {:ok,
     socket
     |> assign(
       page_title: "Database",
       restoring: false,
       restore_result: nil,
       tables: list_tables()
     )
     |> allow_upload(:dump_file,
       accept: ~w(.json),
       max_entries: 1,
       max_file_size: @max_upload_size
     )}
  end

  @impl true
  def handle_info({:restore_finished, status, message}, socket) do
    {:noreply, restored(socket, {status, message})}
  end

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
  # A restore replaces the application's data, so it is challenged every time
  # rather than covered by an elevation window. An unlock earned for editing a
  # setting is not authority to replace the data.
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

  def handle_event("submit_action_code", %{"code" => code}, socket) do
    ActionCode.submit(socket, code)
  end

  def handle_event("cancel_action_code", _params, socket) do
    ActionCode.cancel(socket)
  end

  defp staged([{{:ok, path}, filename}], socket) do
    challenge(Elevation.configured?(), path, filename, socket)
  end

  defp staged([{{:error, reason}, _filename}], socket) do
    {:noreply, put_flash(socket, :error, "Could not stage the upload: #{inspect(reason)}")}
  end

  defp staged([], socket), do: {:noreply, put_flash(socket, :error, "No file uploaded")}

  # A restore replaces the live database, so it is refused outright where no
  # code can be asked for. There is no password-only path to it.
  defp challenge(false, path, filename, socket) do
    Restore.discard(path)

    AlexClawWeb.Live.Elevation.audit_refusal(
      socket,
      :no_second_factor,
      "database restore from #{filename}"
    )

    {:noreply,
     put_flash(
       socket,
       :error,
       "Admin changes require 2FA. Configure a gateway via environment variables and run /setup 2fa."
     )}
  end

  # The action carries the session's fingerprint, never the sid: it waits in
  # the challenge store for the code, and names who asked in the audit rows.
  defp challenge(true, path, filename, socket) do
    ActionCode.request(
      socket,
      %{
        type: :database_restore,
        path: path,
        filename: filename,
        session: session_print(socket.assigns.elevation_sid)
      },
      "Restore the database from #{filename} — this replaces live data"
    )
  end

  defp session_print(sid) when is_binary(sid), do: AlexClaw.Auth.Elevation.fingerprint(sid)
  defp session_print(_sid), do: "unidentified"

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
  defp upload_error_message(:not_accepted), do: "Only data exports (.json) are accepted"
  defp upload_error_message(err), do: "Error: #{inspect(err)}"
end
