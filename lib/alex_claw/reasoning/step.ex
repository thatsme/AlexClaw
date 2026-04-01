defmodule AlexClaw.Reasoning.Step do
  @moduledoc "Ecto schema for individual steps within a reasoning session."

  use Ecto.Schema
  import Ecto.Changeset

  alias AlexClaw.Reasoning.Session

  @type t :: %__MODULE__{}

  @phases ~w(plan execute evaluate decide user_override)
  @decisions ~w(continue adjust ask_user done stuck)

  schema "reasoning_steps" do
    field :iteration, :integer
    field :phase, :string
    field :skill_name, :string
    field :llm_prompt, :string
    field :llm_response, :string
    field :skill_input, :map, default: %{}
    field :skill_output, :string
    field :decision, :string
    field :confidence, :float
    field :rubric_scores, :map
    field :user_guidance, :string
    field :working_memory_snapshot, :string
    field :duration_ms, :integer
    field :error, :string

    belongs_to :session, Session

    timestamps(type: :utc_datetime)
  end

  @required_fields [:session_id, :iteration, :phase]
  @optional_fields [
    :skill_name, :llm_prompt, :llm_response, :skill_input, :skill_output,
    :decision, :confidence, :rubric_scores, :user_guidance,
    :working_memory_snapshot, :duration_ms, :error
  ]

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(step, attrs) do
    step
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:phase, @phases)
    |> validate_decision()
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:iteration, greater_than_or_equal_to: 1)
    |> validate_number(:duration_ms, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:session_id)
  end

  defp validate_decision(changeset) do
    case get_change(changeset, :decision) do
      nil -> changeset
      decision when decision in @decisions -> changeset
      _ -> add_error(changeset, :decision, "must be one of: #{Enum.join(@decisions, ", ")}")
    end
  end
end
