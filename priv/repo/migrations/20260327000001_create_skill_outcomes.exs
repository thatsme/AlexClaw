defmodule AlexClaw.Repo.Migrations.CreateSkillOutcomes do
  use Ecto.Migration

  def change do
    create table(:skill_outcomes) do
      add :workflow_run_id, references(:workflow_runs, on_delete: :delete_all), null: false
      add :step_position, :integer, null: false
      add :skill_name, :string, null: false
      add :result_quality, :string, default: "neutral"
      add :user_feedback, :text
      add :duration_ms, :integer
      add :output_snapshot, :map, default: %{}
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:skill_outcomes, [:workflow_run_id])
    create index(:skill_outcomes, [:skill_name, :result_quality])
  end
end
