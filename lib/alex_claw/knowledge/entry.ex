defmodule AlexClaw.Knowledge.Entry do
  @moduledoc "Ecto schema for knowledge base entries with vector embeddings."

  use Ecto.Schema
  import Ecto.Changeset

  schema "knowledge_entries" do
    field :kind, :string
    field :content, :string
    field :source, :string
    field :embedding, Pgvector.Ecto.Vector
    field :metadata, :map, default: %{}
    field :expires_at, :utc_datetime
    field :embedding_model, :string
    field :embedding_dim, :integer
    field :embedded_at, :utc_datetime
    field :parent_id, :integer
    field :chunk_index, :integer

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{
          id: integer() | nil,
          kind: String.t(),
          content: String.t(),
          source: String.t() | nil,
          embedding: list(float()) | nil,
          metadata: map(),
          expires_at: DateTime.t() | nil,
          embedding_model: String.t() | nil,
          embedding_dim: integer() | nil,
          embedded_at: DateTime.t() | nil,
          parent_id: integer() | nil,
          chunk_index: integer() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:kind, :content, :source, :embedding, :metadata, :expires_at, :embedding_model, :embedding_dim, :embedded_at, :parent_id, :chunk_index])
    |> validate_required([:kind, :content])
  end
end
