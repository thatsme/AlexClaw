defmodule AlexClaw.Cluster do
  @moduledoc "Context for managing cluster node registration and connectivity."

  import Ecto.Query
  alias AlexClaw.Cluster.ClusterNode
  alias AlexClaw.Repo

  @spec list_nodes() :: [ClusterNode.t()]
  def list_nodes do
    Repo.all(from(n in ClusterNode, order_by: n.name))
  end

  @spec get_node!(integer()) :: ClusterNode.t()
  def get_node!(id), do: Repo.get!(ClusterNode, id)

  @spec get_by_name(String.t()) :: ClusterNode.t() | nil
  def get_by_name(name) do
    Repo.get_by(ClusterNode, name: to_string(name))
  end

  @spec create_node(map()) :: {:ok, ClusterNode.t()} | {:error, Ecto.Changeset.t()}
  def create_node(attrs) do
    %ClusterNode{}
    |> ClusterNode.changeset(attrs)
    |> Repo.insert()
  end

  @spec update_node(ClusterNode.t(), map()) ::
          {:ok, ClusterNode.t()} | {:error, Ecto.Changeset.t()}
  def update_node(%ClusterNode{} = node, attrs) do
    node
    |> ClusterNode.changeset(attrs)
    |> Repo.update()
  end

  @spec delete_node(ClusterNode.t()) :: {:ok, ClusterNode.t()} | {:error, Ecto.Changeset.t()}
  def delete_node(%ClusterNode{} = node), do: Repo.delete(node)

  @doc """
  This node's own row: created on its first boot, touched on every one after.
  The one registration no one asks for — a node is its own — and never
  another node's: a node that merely connects is not registered by
  connecting (`AlexClaw.Cluster.Manager`); registration is the admin UI's
  `save_node`.
  """
  @spec register_self(String.t()) :: {:ok, :created | :touched} | {:error, Ecto.Changeset.t()}
  def register_self(name), do: registered_self(get_by_name(name), name)

  defp registered_self(nil, name) do
    with {:ok, _node} <-
           create_node(%{
             name: name,
             label: name |> String.split("@") |> List.last(),
             status: "connected",
             last_seen_at: DateTime.utc_now()
           }),
         do: {:ok, :created}
  end

  defp registered_self(node, _name) do
    with {:ok, _node} <-
           update_node(node, %{status: "connected", last_seen_at: DateTime.utc_now()}),
         do: {:ok, :touched}
  end

  @doc """
  Record that the registered node `name` is `status` ("connected",
  "disconnected"). A node that is not registered is not recorded:
  `{:error, :not_registered}`.
  """
  @spec mark_status(String.t(), String.t()) ::
          {:ok, ClusterNode.t()} | {:error, :not_registered | Ecto.Changeset.t()}
  def mark_status(name, status), do: marked(get_by_name(name), status)

  defp marked(nil, _status), do: {:error, :not_registered}

  defp marked(node, status),
    do: update_node(node, %{status: status, last_seen_at: DateTime.utc_now()})

  @doc "Ping all registered nodes and update their status."
  @spec refresh_statuses() :: :ok
  def refresh_statuses do
    for node <- list_nodes() do
      status = if node_ping(node.name) == :pong, do: "connected", else: "disconnected"
      update_node(node, %{status: status, last_seen_at: DateTime.utc_now()})
    end

    :ok
  end

  @doc "Return the current BEAM node name as a string."
  @spec self_name() :: String.t()
  def self_name, do: to_string(node())

  @doc "Ping a node by name string. Node names are a bounded set from the DB — safe to create atoms."
  @spec node_ping(String.t()) :: :pong | :pang
  def node_ping(name) when is_binary(name) do
    Node.ping(String.to_existing_atom(name))
  rescue
    ArgumentError -> :pang
  end
end
