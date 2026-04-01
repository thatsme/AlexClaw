defmodule AlexClaw.Repo.Migrations.CreateReasoningTables do
  use Ecto.Migration

  def change do
    create table(:reasoning_sessions) do
      add :goal, :text, null: false
      add :status, :string, null: false, default: "planning"
      add :plan, :map, default: %{}
      add :working_memory, :text
      add :config, :map, default: %{}
      add :delivery_config, :map, default: %{}
      add :result, :text
      add :error, :text
      add :confidence, :float
      add :iteration_count, :integer, default: 0
      add :total_llm_calls, :integer, default: 0
      add :parent_session_id, references(:reasoning_sessions, on_delete: :nilify_all)
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime

      timestamps()
    end

    create index(:reasoning_sessions, [:status])
    create index(:reasoning_sessions, [:parent_session_id])

    create table(:reasoning_steps) do
      add :session_id, references(:reasoning_sessions, on_delete: :delete_all), null: false
      add :iteration, :integer, null: false
      add :phase, :string, null: false
      add :skill_name, :string
      add :llm_prompt, :text
      add :llm_response, :text
      add :skill_input, :map, default: %{}
      add :skill_output, :text
      add :decision, :string
      add :confidence, :float
      add :rubric_scores, :map
      add :user_guidance, :text
      add :working_memory_snapshot, :text
      add :duration_ms, :integer
      add :error, :text

      timestamps()
    end

    create index(:reasoning_steps, [:session_id])
    create index(:reasoning_steps, [:session_id, :iteration])
  end
end
