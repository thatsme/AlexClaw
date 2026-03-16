defmodule AlexClawWeb.AdminLive.Feeds do
  @moduledoc "LiveView page for managing RSS feed resources."

  use Phoenix.LiveView

  alias AlexClaw.Resources

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "RSS Feeds",
       feeds: load_feeds(),
       show_form: false
     )}
  end

  @impl true
  def handle_event("toggle_form", _, socket) do
    {:noreply, assign(socket, show_form: !socket.assigns.show_form)}
  end

  @impl true
  def handle_event("add_feed", %{"name" => name, "url" => url}, socket) do
    case Resources.create_resource(%{name: name, type: "rss_feed", url: url, enabled: true}) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Feed '#{name}' added")
         |> assign(feeds: load_feeds(), show_form: false)}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "Error: #{inspect(changeset.errors)}")}
    end
  end

  @impl true
  def handle_event("delete_feed", %{"id" => id}, socket) do
    case parse_id(id) do
      {:ok, rid} ->
        case Resources.get_resource(rid) do
          {:ok, resource} ->
            {:ok, _} = Resources.delete_resource(resource)

            {:noreply,
             socket
             |> put_flash(:info, "Feed removed")
             |> assign(feeds: load_feeds())}

          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "Feed not found")}
        end

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_feed", %{"id" => id}, socket) do
    case parse_id(id) do
      {:ok, rid} ->
        case Resources.get_resource(rid) do
          {:ok, resource} ->
            {:ok, _} = Resources.update_resource(resource, %{enabled: !resource.enabled})
            {:noreply, assign(socket, feeds: load_feeds())}

          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "Feed not found")}
        end

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

  defp load_feeds do
    Resources.list_resources(%{type: "rss_feed"})
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-8">
      <div class="flex justify-between items-center">
        <h1 class="text-2xl font-bold text-white">RSS Feeds</h1>
        <button phx-click="toggle_form" class="px-4 py-2 bg-claw-700 hover:bg-claw-600 text-white text-sm rounded transition">
          {if @show_form, do: "Cancel", else: "Add Feed"}
        </button>
      </div>

      <div :if={@show_form} class="bg-gray-900 rounded-lg border border-gray-800 p-6">
        <form phx-submit="add_feed" class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <div>
            <label class="block text-sm text-gray-400 mb-1">Feed Name</label>
            <input type="text" name="name" required placeholder="My Feed"
              class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-2 text-white text-sm" />
          </div>
          <div>
            <label class="block text-sm text-gray-400 mb-1">Feed URL</label>
            <input type="url" name="url" required placeholder="https://example.com/feed.rss"
              class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-2 text-white text-sm" />
          </div>
          <div class="md:col-span-2">
            <button type="submit" class="px-4 py-2 bg-green-700 hover:bg-green-600 text-white text-sm rounded transition">
              Add Feed
            </button>
          </div>
        </form>
      </div>

      <div class="bg-gray-900 rounded-lg border border-gray-800 overflow-hidden">
        <table class="w-full">
          <thead class="bg-gray-800">
            <tr>
              <th class="px-4 py-3 text-left text-xs text-gray-400 uppercase">Name</th>
              <th class="px-4 py-3 text-left text-xs text-gray-400 uppercase">URL</th>
              <th class="px-4 py-3 text-left text-xs text-gray-400 uppercase">Status</th>
              <th class="px-4 py-3 text-right text-xs text-gray-400 uppercase">Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@feeds == []} class="border-t border-gray-800">
              <td colspan="4" class="px-4 py-8 text-center text-gray-500">No feeds. Add one or manage resources at <a href="/resources?type=rss_feed" class="text-claw-500">/resources</a>.</td>
            </tr>
            <tr :for={feed <- @feeds} class="border-t border-gray-800">
              <td class="px-4 py-3 text-sm font-semibold text-white">{feed.name}</td>
              <td class="px-4 py-3 text-sm text-gray-400 font-mono truncate max-w-md">{feed.url}</td>
              <td class="px-4 py-3">
                <button phx-click="toggle_feed" phx-value-id={feed.id}>
                  <span :if={feed.enabled} class="text-xs px-2 py-1 rounded bg-green-900 text-green-300">enabled</span>
                  <span :if={!feed.enabled} class="text-xs px-2 py-1 rounded bg-gray-800 text-gray-500">disabled</span>
                </button>
              </td>
              <td class="px-4 py-3 text-right">
                <button phx-click="delete_feed" phx-value-id={feed.id}
                  data-confirm="Remove this feed?"
                  class="text-xs text-red-500 hover:text-red-400">Remove</button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
