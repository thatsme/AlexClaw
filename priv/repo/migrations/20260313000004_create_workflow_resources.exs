defmodule AlexClaw.Repo.Migrations.CreateWorkflowResources do
  use Ecto.Migration

  def change do
    create table(:workflow_resources) do
      add :workflow_id, references(:workflows, on_delete: :delete_all), null: false
      add :resource_id, references(:resources, on_delete: :delete_all), null: false
      add :role, :string, default: "input"

      timestamps(updated_at: false)
    end

    create unique_index(:workflow_resources, [:workflow_id, :resource_id])
  end
end
