defmodule AlexClaw.Repo.Migrations.AlterMemoriesEmbedding768 do
  use Ecto.Migration

  def up do
    execute("DROP INDEX IF EXISTS memories_embedding_idx")
    execute("ALTER TABLE memories ALTER COLUMN embedding TYPE vector(768)")

    execute("""
    CREATE INDEX memories_embedding_idx
    ON memories USING hnsw (embedding vector_cosine_ops)
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS memories_embedding_idx")
    execute("ALTER TABLE memories ALTER COLUMN embedding TYPE vector(1536)")

    execute("""
    CREATE INDEX memories_embedding_idx
    ON memories USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100)
    """)
  end
end
