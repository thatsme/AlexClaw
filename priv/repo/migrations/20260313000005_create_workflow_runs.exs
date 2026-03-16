defmodule AlexClaw.Repo.Migrations.CreateWorkflowRuns do
  use Ecto.Migration

  def change do
    create table(:workflow_runs) do
      add :workflow_id, references(:workflows, on_delete: :nilify_all)
      add :status, :string, null: false, default: "running"
      add :started_at, :utc_datetime, null: false
      add :completed_at, :utc_datetime
      add :result, :map, default: %{}
      add :error, :text
      add :step_results, :map, default: %{}

      timestamps()
    end

    create index(:workflow_runs, [:workflow_id, :status])
  end
end
