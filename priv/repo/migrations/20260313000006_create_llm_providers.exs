defmodule AlexClaw.Repo.Migrations.CreateLlmProviders do
  use Ecto.Migration

  def change do
    create table(:llm_providers) do
      add :name, :string, null: false
      add :type, :string, null: false, default: "openai_compatible"
      add :tier, :string, null: false
      add :host, :string, null: false
      add :model, :string, null: false
      add :api_key, :string
      add :daily_limit, :integer
      add :headers, :map, default: %{}
      add :enabled, :boolean, default: true

      timestamps()
    end

    create unique_index(:llm_providers, [:name])
  end
end
