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
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:kind, :content, :source, :embedding, :metadata, :expires_at])
    |> validate_required([:kind, :content])
  end
end
