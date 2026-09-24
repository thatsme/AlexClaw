defmodule AlexClaw.Workflows.Workflow do
  @moduledoc "Schema for a multi-step automation workflow with optional cron scheduling."

  use Ecto.Schema
  import Ecto.Changeset

  alias Crontab.CronExpression.Parser

  @type t :: %__MODULE__{}

  schema "workflows" do
    field(:name, :string)
    field(:description, :string)
    field(:enabled, :boolean, default: true)
    field(:schedule, :string)
    field(:metadata, :map, default: %{})
    field(:default_provider, :string)
    field(:node, :string)

    has_many(:steps, AlexClaw.Workflows.WorkflowStep, preload_order: [asc: :position])
    has_many(:workflow_resources, AlexClaw.Workflows.WorkflowResource)
    has_many(:resources, through: [:workflow_resources, :resource])
    has_many(:runs, AlexClaw.Workflows.WorkflowRun)

    timestamps(type: :utc_datetime)
  end

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(workflow, attrs) do
    workflow
    |> cast(attrs, [:name, :description, :enabled, :schedule, :metadata, :default_provider, :node])
    |> normalize_requires_2fa()
    |> validate_required([:name])
    |> validate_cron()
    |> validate_unscheduled_when_protected()
    |> unique_constraint(:name)
  end

  @doc """
  Whether a person must approve each run of this workflow (the `requires_2fa`
  flag). The one reading of the flag: a value the form sends for a ticked box
  counts, anything else does not.
  """
  @spec protected?(t() | map()) :: boolean()
  def protected?(%{metadata: %{"requires_2fa" => value}}), do: ticked?(value)
  def protected?(_workflow), do: false

  defp ticked?(value), do: value in [true, "true", "on"]

  # Stored as a boolean, so every reader agrees.
  defp normalize_requires_2fa(changeset),
    do: put_normalized(changeset, get_change(changeset, :metadata))

  defp put_normalized(changeset, %{"requires_2fa" => value} = metadata),
    do: put_change(changeset, :metadata, %{metadata | "requires_2fa" => ticked?(value)})

  defp put_normalized(changeset, _metadata), do: changeset

  # A schedule the scheduler cannot parse would never run: refused when saved.
  defp validate_cron(changeset), do: check_cron(get_change(changeset, :schedule), changeset)

  defp check_cron(schedule, changeset) when schedule in [nil, ""], do: changeset

  defp check_cron(schedule, changeset) do
    case parse_cron(schedule, length(String.split(schedule))) do
      {:ok, _expression} -> changeset
      {:error, reason} -> add_error(changeset, :schedule, "is not a cron expression: #{reason}")
    end
  end

  # Five fields, or an @-shortcut (@daily). The parser alone would read "* * *"
  # as "* * * * *" — every minute.
  defp parse_cron("@" <> _ = schedule, _fields), do: Parser.parse(schedule)
  defp parse_cron(schedule, 5), do: Parser.parse(schedule)
  defp parse_cron(_schedule, fields), do: {:error, "#{fields} fields, expected 5"}

  # A schedule runs with nobody there to approve it, so a protected workflow
  # cannot have one — refused whichever of the two is set second.
  defp validate_unscheduled_when_protected(changeset) do
    scheduled? = get_field(changeset, :schedule) not in [nil, ""]
    protected? = protected?(%{metadata: get_field(changeset, :metadata) || %{}})
    unscheduled_when_protected(changeset, scheduled? and protected?)
  end

  defp unscheduled_when_protected(changeset, true),
    do:
      add_error(
        changeset,
        :schedule,
        "cannot be set on a workflow that requires 2FA: each run needs a person's approval"
      )

  defp unscheduled_when_protected(changeset, false), do: changeset
end
