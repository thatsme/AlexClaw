defmodule AlexClaw.Cluster do
  @moduledoc "Context for managing cluster node registration and connectivity."

  import Ecto.Query
  alias AlexClaw.Repo
  alias AlexClaw.Cluster.ClusterNode

  @spec list_nodes() :: [ClusterNode.t()]
  def list_nodes do
    Repo.all(from n in ClusterNode, order_by: n.name)
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

  @spec update_node(ClusterNode.t(), map()) :: {:ok, ClusterNode.t()} | {:error, Ecto.Changeset.t()}
  def update_node(%ClusterNode{} = node, attrs) do
    node
    |> ClusterNode.changeset(attrs)
    |> Repo.update()
  end

  @spec delete_node(ClusterNode.t()) :: {:ok, ClusterNode.t()} | {:error, Ecto.Changeset.t()}
  def delete_node(%ClusterNode{} = node), do: Repo.delete(node)

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
    Node.ping(String.to_atom(name))
  end
end
