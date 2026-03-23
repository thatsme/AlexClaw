defmodule AlexClaw.Repo.Migrations.AddNodeToWorkflowRuns do
  use Ecto.Migration

  def change do
    alter table(:workflow_runs) do
      add :node, :string
    end
  end
end
