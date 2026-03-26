defmodule AlexClawWeb.AdminLive.Cluster do
  @moduledoc "LiveView page for managing BEAM cluster nodes."
  use Phoenix.LiveView

  alias AlexClaw.Cluster

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(30_000, :refresh)

    self_name = Cluster.self_name()

    {:ok,
     assign(socket,
       page_title: "Cluster",
       nodes: remote_nodes(self_name),
       self_node: self_name,
       show_form: false
     )}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Cluster.refresh_statuses()
    {:noreply, assign(socket, nodes: remote_nodes(socket.assigns.self_node))}
  end

  @impl true
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("toggle_form", _, socket) do
    {:noreply, assign(socket, show_form: !socket.assigns.show_form)}
  end

  @impl true
  def handle_event("refresh", _, socket) do
    Cluster.refresh_statuses()
    {:noreply, assign(socket, nodes: remote_nodes(socket.assigns.self_node))}
  end

  @impl true
  def handle_event("add_node", %{"name" => name, "label" => label}, socket) do
    case Cluster.create_node(%{name: String.trim(name), label: String.trim(label)}) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Node added")
         |> assign(nodes: remote_nodes(socket.assigns.self_node), show_form: false)}

      {:error, changeset} ->
        msg =
          Enum.map_join(Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end), ", ", fn {k, v} -> "#{k}: #{Enum.join(v, ", ")}" end)

        {:noreply, put_flash(socket, :error, "Failed: #{msg}")}
    end
  end

  @impl true
  def handle_event("connect", %{"id" => id}, socket) do
    node = Cluster.get_node!(String.to_integer(id))
    status = if Cluster.node_ping(node.name) == :pong, do: "connected", else: "disconnected"
    Cluster.update_node(node, %{status: status, last_seen_at: DateTime.utc_now()})
    {:noreply, assign(socket, nodes: remote_nodes(socket.assigns.self_node))}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    node = Cluster.get_node!(String.to_integer(id))
    Cluster.node_ping(node.name)
    Cluster.delete_node(node)

    {:noreply,
     socket
     |> put_flash(:info, "Node '#{node.name}' removed")
     |> assign(nodes: remote_nodes(socket.assigns.self_node))}
  end

  defp remote_nodes(self_name) do
    Enum.reject(Cluster.list_nodes(), fn n -> n.name == self_name end)
  end
end
