defmodule AlexClawWeb.AdminLive.Memory do
  @moduledoc "LiveView page for browsing, searching, and filtering stored memory entries."

  use Phoenix.LiveView


  @impl true
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

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-8">
      <h1 class="text-2xl font-bold text-white">Memory</h1>

      <div class="flex gap-4">
        <form phx-submit="search" class="flex-1">
          <input type="text" name="query" value={@search_query} placeholder="Search memories..."
            class="w-full bg-gray-800 border border-gray-700 rounded px-4 py-2 text-white text-sm" />
        </form>
        <form phx-change="filter_kind">
          <select name="kind" class="bg-gray-800 border border-gray-700 rounded px-4 py-2 text-white text-sm">
            <option value="">All kinds</option>
            <option :for={kind <- ~w(fact summary news_item conversation)} value={kind} selected={@filter_kind == kind}>
              {kind}
            </option>
          </select>
        </form>
      </div>

      <div class="space-y-2">
        <div :if={@entries == []} class="text-center text-gray-500 py-12">No memories found.</div>
        <div :for={entry <- @entries} class="bg-gray-900 rounded-lg border border-gray-800 p-4">
          <div class="flex items-center justify-between mb-2">
            <div class="flex items-center gap-2">
              <span class={["text-xs px-2 py-0.5 rounded",
                entry.kind == "news_item" && "bg-blue-900 text-blue-300",
                entry.kind == "summary" && "bg-purple-900 text-purple-300",
                entry.kind == "conversation" && "bg-green-900 text-green-300",
                entry.kind == "fact" && "bg-yellow-900 text-yellow-300",
                entry.kind not in ~w(news_item summary conversation fact) && "bg-gray-800 text-gray-400"
              ]}>{entry.kind}</span>
              <span :if={entry.source} class="text-xs text-gray-600 truncate max-w-xs">{entry.source}</span>
            </div>
            <div class="flex items-center gap-3">
              <span class="text-xs text-gray-600">{AlexClawWeb.TimeHelpers.format_datetime(entry.inserted_at)}</span>
              <button phx-click="delete" phx-value-id={entry.id}
                data-confirm="Delete this memory?"
                class="text-xs text-red-500 hover:text-red-400">Delete</button>
            </div>
          </div>
          <p class="text-sm text-gray-300 whitespace-pre-wrap">{String.slice(entry.content, 0, 500)}</p>
        </div>
      </div>
    </div>
    """
  end

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {i, ""} -> {:ok, i}
      _ -> :error
    end
  end
end
