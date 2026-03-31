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
    field :routes, {:array, :map}, default: []

    timestamps(type: :utc_datetime)
  end

  @spec changeset(%__MODULE__{} | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(step, attrs) do
    step
    |> cast(attrs, [:workflow_id, :position, :name, :skill, :llm_tier, :llm_model, :prompt_template, :config, :input_from, :routes])
    |> validate_required([:position, :name, :skill])
    |> validate_tier()
    |> foreign_key_constraint(:workflow_id)
  end

  defp validate_tier(changeset) do
    case get_change(changeset, :llm_tier) do
      nil -> changeset
      value when value in @allowed_tiers -> changeset
      _ -> add_error(changeset, :llm_tier, "must be one of: #{Enum.join(@allowed_tiers, ", ")}")
    end
  end
end
