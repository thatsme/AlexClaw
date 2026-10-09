defmodule AlexClawWeb.AdminLive.Connections do
  @moduledoc """
  Database connections: the PostgreSQL servers `sql_query` steps read from.

  Every change goes through the control plane with the editing elevation
  (`save_connection`, `delete_connection`, `test_connection`). The password
  field is never filled in: a blank one keeps the stored password, unless the
  connection now points at another server. The TLS mode is chosen, never
  preselected.
  """
  use Phoenix.LiveView

  alias AlexClaw.Connections
  alias AlexClaw.Connections.{Connection, Pools}
  alias AlexClawWeb.Live.Elevation

  # What the weaker modes cost the password: the client answers a server's
  # request for it in clear (SECURITY.md, Known Limitations).
  @tls_labels %{
    "disable" => "disable — no TLS: password readable on the network path",
    "require" =>
      "require — encrypted, server identity not verified: an impostor can obtain the password",
    "verify_full" => "verify_full — encrypted, server certificate and host name verified"
  }

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, session, socket) do
    socket
    |> Elevation.assign_elevation(session)
    |> assign(
      page_title: "Connections",
      tls_modes: Enum.map(Connection.tls_modes(), &{&1, @tls_labels[&1]})
    )
    |> listed()
    |> then(&{:ok, &1})
  end

  @impl true
  def handle_info({:elevation, _state, _detail} = message, socket),
    do: {:noreply, Elevation.handle_broadcast(socket, message)}

  @impl true
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("toggle_form", _params, socket),
    do: {:noreply, assign(socket, show_form: !socket.assigns.show_form, editing: nil)}

  def handle_event("cancel_form", _params, socket),
    do: {:noreply, assign(socket, show_form: false, editing: nil)}

  def handle_event("edit", %{"id" => id}, socket), do: {:noreply, edit(found(id), socket)}

  def handle_event("save", params, socket) do
    editing = socket.assigns.editing
    attrs = attrs(params)

    Elevation.perform(
      socket,
      :save_connection,
      %{
        connection: editing,
        attrs: attrs,
        detail: "connection saved: #{saved_name(editing, attrs)}"
      },
      ok: fn socket, conn ->
        socket
        |> put_flash(:info, "Connection #{conn.name} saved")
        |> listed()
      end,
      error: &refused/2
    )
  end

  def handle_event("delete", %{"id" => id}, socket), do: delete(found(id), socket)
  def handle_event("test", %{"id" => id}, socket), do: test(found(id), socket)

  def handle_event("unlock_editing", _params, socket), do: Elevation.open_entry(socket)

  def handle_event("submit_code", %{"code" => code}, socket),
    do: Elevation.submit_code(socket, code)

  def handle_event("cancel_code", _params, socket), do: Elevation.close_entry(socket)

  defp edit({:ok, conn}, socket), do: assign(socket, editing: conn, show_form: true)
  defp edit(:error, socket), do: put_flash(socket, :error, "Connection not found")

  defp delete({:ok, conn}, socket) do
    Elevation.perform(
      socket,
      :delete_connection,
      %{connection_id: conn.id, detail: "connection deleted: #{conn.name}"},
      ok: fn socket, deleted ->
        socket
        |> put_flash(:info, "Connection #{deleted.name} deleted")
        |> listed()
      end,
      error: &refused/2
    )
  end

  defp delete(:error, socket), do: {:noreply, put_flash(socket, :error, "Connection not found")}

  defp test({:ok, conn}, socket) do
    Elevation.perform(
      socket,
      :test_connection,
      %{connection_id: conn.id, detail: "connection tested: #{conn.name}"},
      ok: fn socket, name ->
        socket
        |> put_flash(:info, "#{name}: connected")
        |> listed()
      end,
      error: &refused/2
    )
  end

  defp test(:error, socket), do: {:noreply, put_flash(socket, :error, "Connection not found")}

  defp found(id) do
    with {int, ""} <- Integer.parse(to_string(id)),
         {:ok, conn} <- Connections.get_connection(int) do
      {:ok, conn}
    else
      _other -> :error
    end
  end

  defp refused(socket, %Ecto.Changeset{} = changeset),
    do: put_flash(socket, :error, "Not saved: #{errors(changeset)}")

  defp refused(socket, {:in_use, workflows}),
    do:
      put_flash(
        socket,
        :error,
        "In use by the workflows #{Enum.join(workflows, ", ")}: not deleted"
      )

  defp refused(socket, {:internal_target, why}),
    do: put_flash(socket, :error, "Not saved: #{why}")

  defp refused(socket, {:connection_down, reason}),
    do: put_flash(socket, :error, "Not connected: #{reason}")

  defp refused(socket, reason), do: put_flash(socket, :error, "Refused: #{inspect(reason)}")

  # The messages only, never a changed value.
  defp errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  defp saved_name(%Connection{name: name}, _attrs), do: name
  defp saved_name(nil, attrs), do: attrs[:name]

  defp attrs(params) do
    %{
      name: params["name"],
      host: params["host"],
      port: params["port"],
      database: params["database"],
      username: params["username"],
      tls_mode: params["tls_mode"],
      password: params["password"] || ""
    }
  end

  defp listed(socket) do
    assign(socket,
      connections: Connections.list_connections(),
      statuses: Map.new(Pools.statuses(), &{&1.name, &1}),
      show_form: false,
      editing: nil
    )
  end
end
