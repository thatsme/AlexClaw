defmodule AlexClaw.Repo.Migrations.CreateWorkflowSteps do
  use Ecto.Migration

  def change do
    create table(:workflow_steps) do
      add :workflow_id, references(:workflows, on_delete: :delete_all), null: false
      add :position, :integer, null: false
      add :name, :string, null: false
      add :skill, :string, null: false
      add :llm_tier, :string
      add :llm_model, :string
      add :prompt_template, :text
      add :config, :map, default: %{}

      timestamps()
    end

    create index(:workflow_steps, [:workflow_id, :position])
  end
end
