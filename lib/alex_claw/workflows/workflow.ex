defmodule AlexClaw.Workflows.Workflow do
  @moduledoc "Schema for a multi-step automation workflow with optional cron scheduling."

  use Ecto.Schema
  import Ecto.Changeset

  schema "workflows" do
    field :name, :string
    field :description, :string
    field :enabled, :boolean, default: true
    field :schedule, :string
    field :metadata, :map, default: %{}
    field :default_provider, :string
    field :node, :string

    has_many :steps, AlexClaw.Workflows.WorkflowStep, preload_order: [asc: :position]
    has_many :workflow_resources, AlexClaw.Workflows.WorkflowResource
    has_many :resources, through: [:workflow_resources, :resource]
    has_many :runs, AlexClaw.Workflows.WorkflowRun

    timestamps(type: :utc_datetime)
  end

  def changeset(workflow, attrs) do
    workflow
    |> cast(attrs, [:name, :description, :enabled, :schedule, :metadata, :default_provider, :node])
    |> validate_required([:name])
    |> unique_constraint(:name)
  end
end
