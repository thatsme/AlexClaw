defmodule AlexClaw.Repo.Migrations.AddDefaultProviderToWorkflows do
  use Ecto.Migration

  def change do
    alter table(:workflows) do
      add :default_provider, :string
    end
  end
end
