defmodule AlexClawWeb.AdminLive.Resources do
  @moduledoc "LiveView page for CRUD management of resources with type filtering."

  use Phoenix.LiveView

  alias AlexClaw.Resources

  @resource_types ~w(rss_feed website document api automation)

  @impl true
  def mount(params, _session, socket) do
    type_filter = params["type"]

    {:ok,
     assign(socket,
       page_title: "Resources",
       resources: list_resources(type_filter),
       type_filter: type_filter,
       resource_types: @resource_types,
       show_form: false,
       editing: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    type_filter = params["type"]

    {:noreply,
     assign(socket,
       type_filter: type_filter,
       resources: list_resources(type_filter)
     )}
  end

  @impl true
  def handle_event("toggle_form", _, socket) do
    {:noreply, assign(socket, show_form: !socket.assigns.show_form, editing: nil)}
  end

  @impl true
  def handle_event("edit", %{"id" => id}, socket) do
    case parse_id(id) do
      {:ok, rid} ->
        case Resources.get_resource(rid) do
          {:ok, resource} -> {:noreply, assign(socket, editing: resource, show_form: true)}
          {:error, :not_found} -> {:noreply, put_flash(socket, :error, "Resource not found")}
        end

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("save", params, socket) do
    metadata = case Jason.decode(params["metadata"] || "") do
      {:ok, map} when is_map(map) -> map
      _ -> nil
    end

    attrs = %{
      name: params["name"],
      type: params["type"],
      url: params["url"],
      content: params["content"],
      tags: parse_tags(params["tags"]),
      enabled: params["enabled"] == "true"
    }

    attrs = if metadata, do: Map.put(attrs, :metadata, metadata), else: attrs

    result =
      case socket.assigns.editing do
        nil -> Resources.create_resource(attrs)
        resource -> Resources.update_resource(resource, attrs)
      end

    case result do
      {:ok, _resource} ->
        action = if socket.assigns.editing, do: "updated", else: "created"

        {:noreply,
         socket
         |> put_flash(:info, "Resource #{action}")
         |> assign(
           resources: list_resources(socket.assigns.type_filter),
           show_form: false,
           editing: nil
         )}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "Error: #{inspect(changeset.errors)}")}
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    case parse_id(id) do
      {:ok, rid} ->
        case Resources.get_resource(rid) do
          {:ok, resource} ->
            {:ok, _} = Resources.delete_resource(resource)

            {:noreply,
             socket
             |> put_flash(:info, "Resource deleted")
             |> assign(resources: list_resources(socket.assigns.type_filter))}

          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "Resource not found")}
        end

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_enabled", %{"id" => id}, socket) do
    case parse_id(id) do
      {:ok, rid} ->
        case Resources.get_resource(rid) do
          {:ok, resource} ->
            {:ok, _} = Resources.update_resource(resource, %{enabled: !resource.enabled})
            {:noreply, assign(socket, resources: list_resources(socket.assigns.type_filter))}

          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "Resource not found")}
        end

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("filter_type", %{"type" => ""}, socket) do
    {:noreply, push_patch(socket, to: "/resources")}
  end

  @impl true
  def handle_event("filter_type", %{"type" => type}, socket) do
    {:noreply, push_patch(socket, to: "/resources?type=#{type}")}
  end

  defp list_resources(nil), do: Resources.list_resources()
  defp list_resources(type), do: Resources.list_resources(%{type: type})

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {i, ""} -> {:ok, i}
      _ -> :error
    end
  end

  defp parse_tags(nil), do: []
  defp parse_tags(""), do: []
  defp parse_tags(tags), do: tags |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-8">
      <div class="flex justify-between items-center">
        <h1 class="text-2xl font-bold text-white">Resources</h1>
        <div class="flex items-center space-x-3">
          <form phx-change="filter_type">
            <select name="type"
              class="bg-gray-800 border border-gray-700 rounded px-3 py-2 text-white text-sm">
              <option value="">All Types</option>
              <option :for={t <- @resource_types} value={t} selected={@type_filter == t}>{t}</option>
            </select>
          </form>
          <button phx-click="toggle_form" class="px-4 py-2 bg-claw-700 hover:bg-claw-600 text-white text-sm rounded transition">
            {if @show_form, do: "Cancel", else: "Add Resource"}
          </button>
        </div>
      </div>

      <div :if={@show_form} class="bg-gray-900 rounded-lg border border-gray-800 p-6">
        <h2 class="text-lg font-semibold text-white mb-4">{if @editing, do: "Edit Resource", else: "New Resource"}</h2>
        <form phx-submit="save" class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <div>
            <label class="block text-sm text-gray-400 mb-1">Name</label>
            <input type="text" name="name" required value={if @editing, do: @editing.name, else: ""}
              class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-2 text-white text-sm" />
          </div>
          <div>
            <label class="block text-sm text-gray-400 mb-1">Type</label>
            <select name="type" class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-2 text-white text-sm">
              <option :for={t <- @resource_types} value={t} selected={@editing && @editing.type == t}>{t}</option>
            </select>
          </div>
          <div>
            <label class="block text-sm text-gray-400 mb-1">URL</label>
            <input type="text" name="url" value={if @editing, do: @editing.url, else: ""}
              placeholder="https://..."
              class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-2 text-white text-sm" />
          </div>
          <div>
            <label class="block text-sm text-gray-400 mb-1">Tags (comma-separated)</label>
            <input type="text" name="tags" value={if @editing, do: Enum.join(@editing.tags, ", "), else: ""}
              placeholder="news, tech"
              class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-2 text-white text-sm" />
          </div>
          <div class="md:col-span-2">
            <label class="block text-sm text-gray-400 mb-1">Content (for inline documents)</label>
            <textarea name="content" rows="3"
              class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-2 text-white text-sm">{if @editing, do: @editing.content, else: ""}</textarea>
          </div>
          <div class="md:col-span-2">
            <label class="block text-sm text-gray-400 mb-1">Metadata (JSON — automation config, API params, etc.)</label>
            <textarea name="metadata" rows="6"
              class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-2 text-white text-sm font-mono text-xs">{if @editing && @editing.metadata && @editing.metadata != %{}, do: Jason.encode!(@editing.metadata, pretty: true), else: ""}</textarea>
          </div>
          <div class="flex items-center space-x-2">
            <label class="text-sm text-gray-400">Enabled</label>
            <select name="enabled" class="bg-gray-800 border border-gray-700 rounded px-3 py-2 text-white text-sm">
              <option value="true" selected={!@editing || @editing.enabled}>Yes</option>
              <option value="false" selected={@editing && !@editing.enabled}>No</option>
            </select>
          </div>
          <div class="md:col-span-2">
            <button type="submit" class="px-4 py-2 bg-green-700 hover:bg-green-600 text-white text-sm rounded transition">
              {if @editing, do: "Update", else: "Create"}
            </button>
          </div>
        </form>
      </div>

      <div class="bg-gray-900 rounded-lg border border-gray-800 overflow-hidden">
        <table class="w-full">
          <thead class="bg-gray-800">
            <tr>
              <th class="px-4 py-3 text-left text-xs text-gray-400 uppercase">Name</th>
              <th class="px-4 py-3 text-left text-xs text-gray-400 uppercase">Type</th>
              <th class="px-4 py-3 text-left text-xs text-gray-400 uppercase">URL</th>
              <th class="px-4 py-3 text-left text-xs text-gray-400 uppercase">Tags</th>
              <th class="px-4 py-3 text-left text-xs text-gray-400 uppercase">Status</th>
              <th class="px-4 py-3 text-right text-xs text-gray-400 uppercase">Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@resources == []} class="border-t border-gray-800">
              <td colspan="6" class="px-4 py-8 text-center text-gray-500">No resources found</td>
            </tr>
            <tr :for={resource <- @resources} class="border-t border-gray-800">
              <td class="px-4 py-3 text-sm font-semibold text-white">{resource.name}</td>
              <td class="px-4 py-3">
                <span class="text-xs px-2 py-1 rounded bg-gray-800 text-claw-500 font-mono">{resource.type}</span>
              </td>
              <td class="px-4 py-3 text-sm text-gray-400 font-mono truncate max-w-xs">
                {resource.url}
                <span :if={resource.metadata && resource.metadata != %{}} class="ml-2 text-xs px-1.5 py-0.5 rounded bg-blue-900 text-blue-300">json</span>
              </td>
              <td class="px-4 py-3">
                <span :for={tag <- resource.tags} class="text-xs px-2 py-0.5 rounded bg-gray-800 text-gray-400 mr-1">{tag}</span>
              </td>
              <td class="px-4 py-3">
                <button phx-click="toggle_enabled" phx-value-id={resource.id}>
                  <span :if={resource.enabled} class="text-xs px-2 py-1 rounded bg-green-900 text-green-300">enabled</span>
                  <span :if={!resource.enabled} class="text-xs px-2 py-1 rounded bg-gray-800 text-gray-500">disabled</span>
                </button>
              </td>
              <td class="px-4 py-3 text-right space-x-2">
                <button phx-click="edit" phx-value-id={resource.id}
                  class="text-xs text-claw-500 hover:text-claw-400">Edit</button>
                <button phx-click="delete" phx-value-id={resource.id}
                  data-confirm="Delete this resource?"
                  class="text-xs text-red-500 hover:text-red-400">Delete</button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
