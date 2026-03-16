defmodule AlexClaw.Repo.Migrations.AddInputFromToWorkflowSteps do
  use Ecto.Migration

  def change do
    alter table(:workflow_steps) do
      add :input_from, :integer, default: nil
    end
  end
end
