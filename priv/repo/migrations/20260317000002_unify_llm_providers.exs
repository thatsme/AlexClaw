defmodule AlexClaw.Repo.Migrations.UnifyLlmProviders do
  use Ecto.Migration

  def change do
    alter table(:llm_providers) do
      add :priority, :integer, default: 100
      modify :host, :string, null: true
    end

    # Migrate llm_usage from atom-based model strings to provider IDs.
    # This is handled in application code (UsageTracker) on first boot.
  end
end
