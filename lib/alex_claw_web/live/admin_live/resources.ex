defmodule AlexClawWeb.AdminLive.Resources do
  @moduledoc "LiveView page for CRUD management of resources with type filtering."

  use Phoenix.LiveView
  alias AlexClawWeb.Live.Elevation

  alias AlexClaw.Resources
  alias AlexClaw.Resources.ApiDiscovery
  alias AlexClaw.WebAutomation.Recording

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
       editing: nil,
       recording_session: nil
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

    Elevation.perform(
      socket,
      :save_resource,
      %{
        resource: editing,
        attrs: resource_attrs(params),
        detail: "resource saved: #{params["name"]}"
      },
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

  # The login goes into the slot and the recording is saved through
  # Resources, which stores it in OpenBao, bound to the recording's origin.
  # The page never renders it back.
  @impl true
  def handle_event(
        "attach_login",
        %{"id" => id, "selector" => selector, "value" => value},
        socket
      ),
      do: attach_login(parse_id(id), selector, value, socket)

  @impl true
  def handle_event("delete", %{"id" => id}, socket), do: delete_resource(parse_id(id), socket)

  @impl true
  def handle_event("toggle_enabled", %{"id" => id}, socket),
    do: toggle_enabled(fetch_resource(id), socket)

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
  def handle_event("discover", %{"id" => id}, socket), do: discover(parse_id(id), socket)

  # Recording and replaying a page start a browser session, and a recording
  # can later hold a login: admin UI only, with the elevation.
  def handle_event("record", %{"url" => url}, socket) do
    Elevation.perform(socket, :record, %{url: String.trim(url)},
      ok: fn socket, text ->
        socket
        |> assign(recording_session: session_of(text))
        |> put_flash(:info, text)
      end,
      error: &not_recorded/2
    )
  end

  def handle_event("stop_recording", _params, socket) do
    Elevation.perform(socket, :record, %{stop: socket.assigns.recording_session},
      ok: fn socket, resource ->
        socket
        |> assign(recording_session: nil, resources: list_resources(socket.assigns.type_filter))
        |> put_flash(:info, "Recording saved as resource #{resource.name} (id #{resource.id})")
      end,
      error: &not_recorded/2
    )
  end

  def handle_event("replay", %{"id" => id}, socket), do: replay(parse_id(id), socket)

  def handle_event("unlock_editing", _params, socket) do
    Elevation.open_entry(socket)
  end

  def handle_event("submit_code", %{"code" => code}, socket) do
    Elevation.submit_code(socket, code)
  end

  def handle_event("cancel_code", _params, socket) do
    Elevation.close_entry(socket)
  end

  defp replay(:error, socket), do: {:noreply, socket}

  defp replay({:ok, id}, socket) do
    Elevation.perform(socket, :replay, %{resource_id: id},
      ok: fn socket, text -> put_flash(socket, :info, text) end,
      error: &not_recorded/2
    )
  end

  defp session_of(text) do
    case Regex.run(~r/Session: `([^`]+)`/, text) do
      [_, id] -> id
      _ -> nil
    end
  end

  # Field names only, never a recorded value: a recording may hold a password.
  defp not_recorded(socket, reasons) when is_list(reasons),
    do: put_flash(socket, :error, "Not saved: " <> Enum.join(reasons, "; "))

  defp not_recorded(socket, %Ecto.Changeset{} = changeset) do
    fields = changeset.errors |> Keyword.keys() |> Enum.map_join(", ", &to_string/1)
    put_flash(socket, :error, "Not saved (#{fields})")
  end

  defp not_recorded(socket, reason), do: put_flash(socket, :error, "Not done: #{inspect(reason)}")

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

  # The fields of a recording still waiting for a login.
  defp login_slots(%{metadata: metadata}) when is_map(metadata),
    do: Recording.login_slots(metadata)

  defp login_slots(_resource), do: []

  defp fetch_resource(id), do: id |> parse_id() |> fetched_resource()

  defp fetched_resource({:ok, rid}), do: Resources.get_resource(rid)
  defp fetched_resource(:error), do: {:error, :invalid_id}

  defp not_saved(socket, :invalid_id), do: socket
  defp not_saved(socket, :not_found), do: put_flash(socket, :error, "Resource not found")
  defp not_saved(socket, :no_login_slot), do: put_flash(socket, :error, "No login needed there")
  defp not_saved(socket, :empty_login), do: put_flash(socket, :error, "Enter the login")

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

  defp attach_login(:error, _selector, _value, socket), do: {:noreply, socket}

  defp attach_login({:ok, id}, selector, value, socket) do
    Elevation.perform(
      socket,
      :attach_login,
      %{
        resource_id: id,
        selector: selector,
        value: value,
        detail: "recording login attached: id #{id}, #{selector}"
      },
      ok: fn socket, _resource ->
        socket
        |> put_flash(:info, "Login attached")
        |> assign(resources: list_resources(socket.assigns.type_filter))
      end,
      error: &not_saved/2
    )
  end

  defp delete_resource(:error, socket), do: {:noreply, socket}

  defp delete_resource({:ok, id}, socket) do
    Elevation.perform(
      socket,
      :delete_resource,
      %{resource_id: id, detail: "resource deleted: id #{id}"},
      ok: fn socket, _resource ->
        socket
        |> put_flash(:info, "Resource deleted")
        |> assign(resources: list_resources(socket.assigns.type_filter))
      end,
      error: &not_saved/2
    )
  end

  defp toggle_enabled({:error, reason}, socket), do: {:noreply, not_saved(socket, reason)}

  defp toggle_enabled({:ok, resource}, socket) do
    Elevation.perform(
      socket,
      :save_resource,
      %{
        resource: resource,
        attrs: %{enabled: !resource.enabled},
        detail: "resource enabled toggled: id #{resource.id}"
      },
      ok: fn socket, _resource ->
        assign(socket, resources: list_resources(socket.assigns.type_filter))
      end,
      error: &not_saved/2
    )
  end

  defp discover(:error, socket), do: {:noreply, socket}

  defp discover({:ok, id}, socket) do
    Elevation.perform(
      socket,
      :discover_resource,
      %{resource_id: id, detail: "resource discovery started: id #{id}"},
      ok: fn socket, resource ->
        put_flash(socket, :info, "API discovery started for #{resource.name}")
      end,
      error: &not_saved/2
    )
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
