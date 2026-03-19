defmodule AlexClaw.Repo.Migrations.CreateKnowledgeEntries do
  use Ecto.Migration

  def up do
    create table(:knowledge_entries) do
      add :kind, :string, null: false
      add :content, :text, null: false
      add :source, :string
      add :metadata, :map, default: %{}
      add :expires_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    execute("ALTER TABLE knowledge_entries ADD COLUMN embedding vector(768)")

    create index(:knowledge_entries, [:kind, :inserted_at])
    create index(:knowledge_entries, [:source])

    execute("""
    CREATE INDEX knowledge_entries_embedding_idx
    ON knowledge_entries USING hnsw (embedding vector_cosine_ops)
    """)
  end

  def down do
    drop table(:knowledge_entries)
  end
end
