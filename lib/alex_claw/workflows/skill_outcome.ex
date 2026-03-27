defmodule AlexClaw.Workflows.SkillOutcome do
  @moduledoc """
  Tracks the outcome of each skill execution within a workflow run.

  Outcomes start as `:neutral` and can be annotated by the user via
  gateway commands (thumbs up/down). Skills can query past outcomes
  to improve future execution quality (episodic memory).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @quality_values ~w(thumbs_up thumbs_down neutral)

  schema "skill_outcomes" do
    belongs_to :workflow_run, AlexClaw.Workflows.WorkflowRun

    field :step_position, :integer
    field :skill_name, :string
    field :result_quality, :string, default: "neutral"
    field :user_feedback, :string
    field :duration_ms, :integer
    field :output_snapshot, :map, default: %{}
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(outcome, attrs) do
    outcome
    |> cast(attrs, [:workflow_run_id, :step_position, :skill_name, :result_quality, :user_feedback, :duration_ms, :output_snapshot, :metadata])
    |> validate_required([:workflow_run_id, :step_position, :skill_name])
    |> validate_inclusion(:result_quality, @quality_values)
    |> foreign_key_constraint(:workflow_run_id)
  end
end
