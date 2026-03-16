defmodule AlexClaw.Workflows.WorkflowResource do
  @moduledoc "Join schema linking workflows to their input/output resources."

  use Ecto.Schema
  import Ecto.Changeset

  schema "workflow_resources" do
    belongs_to :workflow, AlexClaw.Workflows.Workflow
    belongs_to :resource, AlexClaw.Resources.Resource

    field :role, :string, default: "input"

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(wr, attrs) do
    wr
    |> cast(attrs, [:workflow_id, :resource_id, :role])
    |> validate_required([:workflow_id, :resource_id])
    |> unique_constraint([:workflow_id, :resource_id])
    |> foreign_key_constraint(:workflow_id)
    |> foreign_key_constraint(:resource_id)
  end
end
