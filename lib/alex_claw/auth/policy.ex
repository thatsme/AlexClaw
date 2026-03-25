defmodule AlexClaw.Auth.Policy do
  @moduledoc """
  Ecto schema for authorization policy rules.

  Rule types:
  - `rate_limit` — max N calls per window for a permission/skill
  - `time_window` — deny permission outside allowed hours
  - `chain_restriction` — restrict cross-skill invocation
  - `permission_override` — temporary grant/deny with optional expiry
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "auth_policies" do
    field :name, :string
    field :description, :string
    field :rule_type, :string
    field :config, :map, default: %{}
    field :enabled, :boolean, default: true
    field :priority, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  @valid_rule_types ~w(rate_limit time_window chain_restriction permission_override)

  @doc false
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(policy, attrs) do
    policy
    |> cast(attrs, [:name, :description, :rule_type, :config, :enabled, :priority])
    |> validate_required([:name, :rule_type, :config])
    |> validate_inclusion(:rule_type, @valid_rule_types)
  end
end
