defmodule AlexClawWeb.AdminLive.Database do
  @moduledoc "LiveView page for database backup downloads and table inspection."

  use Phoenix.LiveView

  alias AlexClaw.Database.Restore
  alias AlexClawWeb.Live.{ActionCode, Elevation}

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(AlexClaw.PubSub, "database:restore")

    socket =
      socket
      |> Elevation.assign_elevation(session)
      |> ActionCode.assign_action_code()

    {:ok,
     socket
     |> assign(
       page_title: "Database",
       restoring: false,
       restore_result: nil,
       tables: list_tables()
     )}
  end

  @impl true
  def handle_info({:restore_finished, status, message}, socket) do
    {:noreply, restored(socket, {status, message})}
  end

  def handle_info({:elevation, _state, _detail} = message, socket) do
    {:noreply, Elevation.handle_broadcast(socket, message)}
  end

  @impl true
  # Restore is an operator procedure until 0.3.34. The form is gone from the
  # page; an event sent anyway is refused and recorded, never performed.
  def handle_event("restore", _params, socket) do
    Elevation.audit_refusal(socket, :disabled, "database restore")
    {:noreply, put_flash(socket, :error, Restore.refusal())}
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
end
