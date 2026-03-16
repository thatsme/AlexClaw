defmodule AlexClaw.Repo.Migrations.CreateWorkflows do
  use Ecto.Migration

  def change do
    create table(:workflows) do
      add :name, :string, null: false
      add :description, :string
      add :enabled, :boolean, default: true
      add :schedule, :string
      add :metadata, :map, default: %{}

      timestamps()
    end

    create unique_index(:workflows, [:name])
  end
end
