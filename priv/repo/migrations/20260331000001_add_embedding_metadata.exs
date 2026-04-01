defmodule AlexClaw.Repo.Migrations.AddEmbeddingMetadata do
  use Ecto.Migration

  def change do
    alter table(:memories) do
      add :embedding_model, :string
      add :embedding_dim, :integer
      add :embedded_at, :utc_datetime
    end

    alter table(:knowledge_entries) do
      add :embedding_model, :string
      add :embedding_dim, :integer
      add :embedded_at, :utc_datetime
    end
  end
end
