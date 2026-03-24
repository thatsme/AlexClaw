defmodule AlexClaw.Cluster.ClusterNode do
  @moduledoc "Schema for a registered node in the AlexClaw cluster."

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "cluster_nodes" do
    field :name, :string
    field :label, :string
    field :status, :string, default: "unknown"
    field :last_seen_at, :utc_datetime
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(node, attrs) do
    node
    |> cast(attrs, [:name, :label, :status, :last_seen_at, :metadata])
    |> validate_required([:name])
    |> unique_constraint(:name)
  end
end
