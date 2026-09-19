defmodule AlexClawWeb.AdminLive.Resources do
  @moduledoc "LiveView page for CRUD management of resources with type filtering."

  use Phoenix.LiveView

  alias AlexClaw.Resources
  alias AlexClaw.Resources.ApiDiscovery

  @resource_types ~w(rss_feed website document api automation)

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(AlexClaw.PubSub, ApiDiscovery.topic())
    end

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
  @spec handle_params(map(), String.t(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_params(params, _uri, socket) do
    type_filter = params["type"]

    {:noreply,
     assign(socket,
       type_filter: type_filter,
       resources: list_resources(type_filter)
     )}
  end

  @impl true
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
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
    editing = socket.assigns.editing

    editing
    |> persist_resource(resource_attrs(params))
    |> saved_resource(socket, editing)
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

  @impl true
  def handle_event("discover", %{"id" => id}, socket) do
    case parse_id(id) do
      {:ok, rid} ->
        case Resources.get_resource(rid) do
          {:ok, resource} ->
            ApiDiscovery.run_async(resource)
            {:noreply, put_flash(socket, :info, "API discovery started for #{resource.name}")}

          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "Resource not found")}
        end

      :error ->
        {:noreply, socket}
    end
  end

  defp resource_attrs(params) do
    %{
      name: params["name"],
      type: params["type"],
      url: params["url"],
      content: params["content"],
      tags: parse_tags(params["tags"]),
      enabled: params["enabled"] == "true"
    }
    |> put_metadata(Jason.decode(params["metadata"] || ""))
  end

  defp put_metadata(attrs, {:ok, map}) when is_map(map), do: Map.put(attrs, :metadata, map)
  defp put_metadata(attrs, _decoded), do: attrs

  defp persist_resource(nil, attrs), do: Resources.create_resource(attrs)
  defp persist_resource(resource, attrs), do: Resources.update_resource(resource, attrs)

  defp saved_resource({:ok, _resource}, socket, editing) do
    action = if editing, do: "updated", else: "created"

    {:noreply,
     socket
     |> put_flash(:info, "Resource #{action}")
     |> assign(
       resources: list_resources(socket.assigns.type_filter),
       show_form: false,
       editing: nil
     )}
  end

  defp saved_resource({:error, changeset}, socket, _editing) do
    {:noreply, put_flash(socket, :error, "Error: #{inspect(changeset.errors)}")}
  end

  @impl true
  def handle_info({:discovery_updated, _resource_id, _status}, socket) do
    {:noreply, assign(socket, resources: list_resources(socket.assigns.type_filter))}
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

  defp parse_tags(tags),
    do: tags |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
end
