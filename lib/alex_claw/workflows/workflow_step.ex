defmodule AlexClaw.Workflows.WorkflowStep do
  @moduledoc "Schema for an individual step within a workflow, binding a skill and optional LLM prompt."

  use Ecto.Schema
  import Ecto.Changeset

  alias AlexClaw.Workflows.{SkillRegistry, StepConfig}

  @allowed_tiers ~w(light medium heavy local)

  schema "workflow_steps" do
    belongs_to(:workflow, AlexClaw.Workflows.Workflow)

    field(:position, :integer)
    field(:name, :string)
    field(:skill, :string)
    field(:llm_tier, :string)
    field(:llm_model, :string)
    field(:prompt_template, :string)
    field(:config, AlexClaw.Encrypted.StepConfig, default: %{})
    field(:input_from, :integer)
    field(:routes, {:array, :map}, default: [])

    timestamps(type: :utc_datetime)
  end

  @spec changeset(%__MODULE__{} | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(step, attrs) do
    step
    |> cast(attrs, [
      :workflow_id,
      :position,
      :name,
      :skill,
      :llm_tier,
      :llm_model,
      :prompt_template,
      :config,
      :input_from,
      :routes
    ])
    |> validate_required([:position, :name, :skill])
    |> validate_tier()
    |> validate_skill_config()
    |> foreign_key_constraint(:workflow_id)
    # References point at positions, so no two steps of a workflow share one.
    |> unique_constraint(:position,
      name: :workflow_steps_workflow_id_position_index,
      message: "is already taken by another step of this workflow"
    )
  end

  # A step is saved only if it can run: its skill exists, is available on this
  # instance, and its config passes the skill's contract (StepConfig).
  defp validate_skill_config(%{valid?: false} = changeset), do: changeset

  defp validate_skill_config(changeset) do
    skill = get_field(changeset, :skill)

    skill
    |> SkillRegistry.resolve()
    |> check_skill(skill, get_field(changeset, :config), changeset)
  end

  defp check_skill({:error, :unknown_skill}, skill, _config, changeset),
    do: add_error(changeset, :skill, "#{skill} does not exist")

  defp check_skill({:ok, module}, skill, config, changeset) do
    if StepConfig.available?(module, config),
      do: check_config(StepConfig.validate(module, config), changeset),
      else: add_error(changeset, :skill, "#{skill} is not configured on this instance")
  end

  defp check_config(:ok, changeset), do: changeset

  defp check_config({:error, reasons}, changeset),
    do: Enum.reduce(reasons, changeset, &add_error(&2, :config, &1))

  defp validate_tier(changeset) do
    case get_change(changeset, :llm_tier) do
      nil -> changeset
      value when value in @allowed_tiers -> changeset
      _ -> add_error(changeset, :llm_tier, "must be one of: #{Enum.join(@allowed_tiers, ", ")}")
    end
  end
end
