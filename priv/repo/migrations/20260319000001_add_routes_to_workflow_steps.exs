defmodule AlexClaw.Repo.Migrations.AddRoutesToWorkflowSteps do
  use Ecto.Migration

  def change do
    alter table(:workflow_steps) do
      add :routes, :jsonb, default: "[]"
    end

    alter table(:dynamic_skills) do
      add :routes, {:array, :string}, default: []
    end
  end
end
