defmodule AlexClaw.Workflows.WorkflowStep do
  @moduledoc "Schema for an individual step within a workflow, binding a skill and optional LLM prompt."

  use Ecto.Schema
  import Ecto.Changeset

  @allowed_tiers ~w(light medium heavy local)

  schema "workflow_steps" do
    belongs_to :workflow, AlexClaw.Workflows.Workflow

    field :position, :integer
    field :name, :string
    field :skill, :string
    field :llm_tier, :string
    field :llm_model, :string
    field :prompt_template, :string
    field :config, :map, default: %{}
    field :input_from, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(step, attrs) do
    step
    |> cast(attrs, [:workflow_id, :position, :name, :skill, :llm_tier, :llm_model, :prompt_template, :config, :input_from])
    |> validate_required([:position, :name, :skill])
    |> validate_inclusion(:llm_tier, @allowed_tiers, message: "must be one of: #{Enum.join(@allowed_tiers, ", ")}")
    |> foreign_key_constraint(:workflow_id)
  end
end
