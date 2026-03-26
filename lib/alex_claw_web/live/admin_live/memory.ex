defmodule AlexClawWeb.AdminLive.Memory do
  @moduledoc "LiveView page for browsing, searching, and filtering stored memory entries."

  use Phoenix.LiveView


  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Memory",
       entries: AlexClaw.Memory.recent(limit: 50),
       search_query: "",
       filter_kind: nil
     )}
  end

  @impl true
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
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
    {:noreply, assign(socket, filter_kind: kind, entries: AlexClaw.Memory.recent(limit: 50, kind: kind))}
  end

  @impl true
  def handle_event("delete", %{"id" => id_str}, socket) do
    case parse_id(id_str) do
      {:ok, id} ->
        AlexClaw.Repo.delete(%AlexClaw.Memory.Entry{id: id})

        {:noreply,
         socket
         |> put_flash(:info, "Memory entry deleted")
         |> assign(entries: AlexClaw.Memory.recent(limit: 50, kind: socket.assigns.filter_kind))}

      :error ->
        {:noreply, socket}
    end
  end

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {i, ""} -> {:ok, i}
      _ -> :error
    end
  end
end
