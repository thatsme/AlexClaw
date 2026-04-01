defmodule AlexClaw.Repo.Migrations.AddChunkingSupport do
  use Ecto.Migration

  def change do
    alter table(:memories) do
      add :parent_id, references(:memories, on_delete: :delete_all)
      add :chunk_index, :integer
    end

    alter table(:knowledge_entries) do
      add :parent_id, references(:knowledge_entries, on_delete: :delete_all)
      add :chunk_index, :integer
    end

    create index(:memories, [:parent_id])
    create index(:knowledge_entries, [:parent_id])
  end
end
