defmodule AlexClaw.Resources.Resource do
  @moduledoc "Schema for external resources such as RSS feeds, websites, documents, and APIs."

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @allowed_types ~w(rss_feed website document api automation)

  schema "resources" do
    field :name, :string
    field :type, :string
    field :url, :string
    field :content, :string
    field :metadata, :map, default: %{}
    field :tags, {:array, :string}, default: []
    field :enabled, :boolean, default: true

    has_many :workflow_resources, AlexClaw.Workflows.WorkflowResource

    timestamps(type: :utc_datetime)
  end

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(resource, attrs) do
    resource
    |> cast(attrs, [:name, :type, :url, :content, :metadata, :tags, :enabled])
    |> validate_required([:name, :type])
    |> validate_inclusion(:type, @allowed_types)
  end
end
