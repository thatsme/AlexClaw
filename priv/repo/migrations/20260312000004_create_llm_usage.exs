defmodule AlexClaw.Repo.Migrations.CreateLlmUsage do
  use Ecto.Migration

  def change do
    create table(:llm_usage) do
      add :model, :string, null: false
      add :date, :date, null: false
      add :count, :integer, null: false, default: 0
    end

    create unique_index(:llm_usage, [:model, :date])
  end
end
