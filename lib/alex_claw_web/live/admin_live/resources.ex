defmodule AlexClawWeb.AdminLive.Resources do
  @moduledoc "LiveView page for CRUD management of resources with type filtering."

  use Phoenix.LiveView
  alias AlexClawWeb.Live.Elevation

  alias AlexClaw.{ControlPlane, Resources}
  alias AlexClaw.Resources.ApiDiscovery

  @resource_types ~w(rss_feed website document api automation)

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(params, session, socket) do
    socket = Elevation.assign_elevation(socket, session)

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

    Elevation.gated(socket, "resource saved: #{params["name"]}",
      write: fn -> persist_resource(editing, resource_attrs(params)) end,
      after_commit: discover_for(socket),
      ok: fn socket, _resource ->
        action = if editing, do: "updated", else: "created"

        socket
        |> put_flash(:info, "Resource #{action}")
        |> assign(
          resources: list_resources(socket.assigns.type_filter),
          show_form: false,
          editing: nil
        )
      end,
      error: &not_saved/2
    )
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    Elevation.gated(socket, "resource deleted: id #{id}",
      write: fn ->
        with {:ok, resource} <- fetch_resource(id), do: Resources.delete_resource(resource)
      end,
      ok: fn socket, _resource ->
        socket
        |> put_flash(:info, "Resource deleted")
        |> assign(resources: list_resources(socket.assigns.type_filter))
      end,
      error: &not_saved/2
    )
  end

  @impl true
  def handle_event("toggle_enabled", %{"id" => id}, socket) do
    Elevation.gated(socket, "resource enabled toggled: id #{id}",
      write: fn ->
        with {:ok, resource} <- fetch_resource(id) do
          Resources.update_resource(resource, %{enabled: !resource.enabled}, skip_discovery: true)
        end
      end,
      after_commit: discover_for(socket),
      ok: fn socket, _resource ->
        assign(socket, resources: list_resources(socket.assigns.type_filter))
      end,
      error: &not_saved/2
    )
  end

  @impl true
  def handle_event("filter_type", %{"type" => ""}, socket) do
    {:noreply, push_patch(socket, to: "/resources")}
  end

  @impl true
  def handle_event("filter_type", %{"type" => type}, socket) do
    {:noreply, push_patch(socket, to: "/resources?type=#{type}")}
  end

  # Discovery writes what it finds to the resource, so asking for it is a
  # change like any other: audited, behind an elevation, and started after the
  # row that records it is committed.
  @impl true
  def handle_event("discover", %{"id" => id}, socket) do
    Elevation.gated(socket, "resource discovery started: id #{id}",
      write: fn -> fetch_resource(id) end,
      after_commit: discover_for(socket),
      ok: fn socket, resource ->
        put_flash(socket, :info, "API discovery started for #{resource.name}")
      end,
      error: &not_saved/2
    )
  end

  def handle_event("unlock_editing", _params, socket) do
    Elevation.open_entry(socket)
  end

  def handle_event("submit_code", %{"code" => code}, socket) do
    Elevation.submit_code(socket, code)
  end

  def handle_event("cancel_code", _params, socket) do
    Elevation.close_entry(socket)
  end

  def handle_event("request_gateway_code", _params, socket) do
    Elevation.unlock(socket)
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

  # Discovery outlives the event, so it carries who asked — by fingerprint and
  # principal, never the sid — to the row it writes when it finishes.
  defp discover_for(socket) do
    requester = ControlPlane.requester(socket.assigns.elevation_sid)
    fn resource -> Resources.discover(resource, requester) end
  end

  # Discovery fetches the API and writes back to the resource, so it is started
  # after commit, never from inside the change.
  defp persist_resource(nil, attrs), do: Resources.create_resource(attrs, skip_discovery: true)

  defp persist_resource(resource, attrs),
    do: Resources.update_resource(resource, attrs, skip_discovery: true)

  defp fetch_resource(id), do: id |> parse_id() |> fetched_resource()

  defp fetched_resource({:ok, rid}), do: Resources.get_resource(rid)
  defp fetched_resource(:error), do: {:error, :invalid_id}

  defp not_saved(socket, :invalid_id), do: socket
  defp not_saved(socket, :not_found), do: put_flash(socket, :error, "Resource not found")

  defp not_saved(socket, %Ecto.Changeset{} = changeset),
    do: put_flash(socket, :error, "Error: #{inspect(changeset.errors)}")

  @impl true
  def handle_info({:elevation, _state, _detail} = message, socket) do
    {:noreply, Elevation.handle_broadcast(socket, message)}
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
