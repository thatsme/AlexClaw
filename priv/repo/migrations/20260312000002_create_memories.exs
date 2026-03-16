defmodule AlexClaw.Repo.Migrations.CreateMemories do
  use Ecto.Migration

  def change do
    create table(:memories) do
      add :kind, :string, null: false
      add :content, :text, null: false
      add :source, :string
      add :embedding, :vector, size: 1536
      add :metadata, :map, default: %{}
      add :expires_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:memories, [:kind, :inserted_at])
    create index(:memories, [:source])

    execute(
      "CREATE INDEX memories_embedding_idx ON memories USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100)",
      "DROP INDEX IF EXISTS memories_embedding_idx"
    )
  end
end
