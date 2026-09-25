defmodule AlexClawWeb.AdminLive.Memory do
  @moduledoc "LiveView page for browsing, searching, and filtering stored memory entries."

  use Phoenix.LiveView
  alias AlexClawWeb.Live.Elevation

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, session, socket) do
    socket = Elevation.assign_elevation(socket, session)

    {:ok,
     assign(socket,
       page_title: "Memory",
       entries: AlexClaw.Memory.recent(limit: 50),
       search_query: "",
       filter_kind: nil
     )}
  end

  @impl true
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("search", %{"query" => query}, socket) do
    entries =
      if String.trim(query) == "" do
        AlexClaw.Memory.recent(limit: 50, kind: socket.assigns.filter_kind)
      else
        AlexClaw.Memory.search(query, limit: 50, kind: socket.assigns.filter_kind)
      end

    {:noreply, assign(socket, entries: entries, search_query: query)}
  end

  @impl true
  def handle_event("filter_kind", %{"kind" => ""}, socket) do
    {:noreply, assign(socket, filter_kind: nil, entries: AlexClaw.Memory.recent(limit: 50))}
  end

  @impl true
  def handle_event("filter_kind", %{"kind" => kind}, socket) do
    {:noreply,
     assign(socket, filter_kind: kind, entries: AlexClaw.Memory.recent(limit: 50, kind: kind))}
  end

  # What the agent remembers shapes what it answers, so removing a memory is a
  # change like any other: audited, and behind an elevation.
  @impl true
  def handle_event("delete", %{"id" => id_str}, socket),
    do: delete_entry(parse_id(id_str), socket)

  def handle_event("unlock_editing", _params, socket), do: Elevation.open_entry(socket)

  def handle_event("submit_code", %{"code" => code}, socket),
    do: Elevation.submit_code(socket, code)

  def handle_event("cancel_code", _params, socket), do: Elevation.close_entry(socket)
  def handle_event("request_gateway_code", _params, socket), do: Elevation.unlock(socket)

  @impl true
  def handle_info({:elevation, _state, _detail} = message, socket) do
    {:noreply, Elevation.handle_broadcast(socket, message)}
  end

  defp delete_entry({:error, reason}, socket), do: {:noreply, not_deleted(socket, reason)}

  defp delete_entry({:ok, id}, socket) do
    Elevation.perform(
      socket,
      :delete_memory,
      %{entry_id: id, detail: "memory entry deleted: id #{id}"},
      ok: fn socket, _entry ->
        socket
        |> put_flash(:info, "Memory entry deleted")
        |> assign(entries: AlexClaw.Memory.recent(limit: 50, kind: socket.assigns.filter_kind))
      end,
      error: &not_deleted/2
    )
  end

  defp not_deleted(socket, :invalid_id), do: socket
  defp not_deleted(socket, :not_found), do: put_flash(socket, :error, "Memory entry not found")

  defp not_deleted(socket, reason),
    do: put_flash(socket, :error, "Not deleted: #{inspect(reason)}")

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {i, ""} -> {:ok, i}
      _ -> {:error, :invalid_id}
    end
  end
end
