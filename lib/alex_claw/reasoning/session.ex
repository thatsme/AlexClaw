defmodule AlexClaw.Reasoning.Session do
  @moduledoc "Ecto schema for reasoning loop sessions."

  use Ecto.Schema
  import Ecto.Changeset

  alias AlexClaw.Reasoning.Step

  @type t :: %__MODULE__{}

  @statuses ~w(planning executing evaluating deciding paused waiting_user completed failed aborted stuck)

  schema "reasoning_sessions" do
    field :goal, :string
    field :status, :string, default: "planning"
    field :plan, :map, default: %{}
    field :working_memory, :string
    field :config, :map, default: %{}
    field :delivery_config, :map, default: %{}
    field :result, :string
    field :error, :string
    field :confidence, :float
    field :iteration_count, :integer, default: 0
    field :total_llm_calls, :integer, default: 0
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime

    belongs_to :parent_session, __MODULE__
    has_many :steps, Step
    has_many :child_sessions, __MODULE__, foreign_key: :parent_session_id

    timestamps(type: :utc_datetime)
  end

  @required_fields [:goal]
  @optional_fields [
    :status, :plan, :working_memory, :config, :delivery_config,
    :result, :error, :confidence, :iteration_count, :total_llm_calls,
    :parent_session_id, :started_at, :completed_at
  ]

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(session, attrs) do
    session
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:iteration_count, greater_than_or_equal_to: 0)
    |> validate_number(:total_llm_calls, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:parent_session_id)
  end
end
