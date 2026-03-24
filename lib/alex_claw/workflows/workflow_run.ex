defmodule AlexClaw.Workflows.WorkflowRun do
  @moduledoc "Schema for a single execution record of a workflow, tracking status and step results."

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "workflow_runs" do
    belongs_to :workflow, AlexClaw.Workflows.Workflow

    field :status, :string, default: "running"
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :result, :map, default: %{}
    field :error, :string
    field :step_results, :map, default: %{}
    field :node, :string

    timestamps(type: :utc_datetime)
  end

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(run, attrs) do
    run
    |> cast(attrs, [:workflow_id, :status, :started_at, :completed_at, :result, :error, :step_results, :node])
    |> validate_required([:status, :started_at])
    |> validate_inclusion(:status, ~w(running completed failed cancelled))
    |> foreign_key_constraint(:workflow_id)
  end
end
