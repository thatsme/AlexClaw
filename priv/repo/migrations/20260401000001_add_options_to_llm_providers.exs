defmodule AlexClaw.Repo.Migrations.AddOptionsToLlmProviders do
  use Ecto.Migration

  def change do
    alter table(:llm_providers) do
      add :options, :map, default: %{}
    end
  end
end
