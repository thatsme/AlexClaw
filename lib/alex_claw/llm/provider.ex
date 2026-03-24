defmodule AlexClaw.LLM.Provider do
  @moduledoc "Schema for LLM provider configurations (all providers live in DB)."

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @allowed_tiers ~w(light medium heavy local)
  @allowed_types ~w(openai_compatible ollama gemini anthropic custom)

  schema "llm_providers" do
    field :name, :string
    field :type, :string, default: "openai_compatible"
    field :tier, :string
    field :host, :string
    field :model, :string
    field :api_key, :string
    field :daily_limit, :integer
    field :headers, :map, default: %{}
    field :enabled, :boolean, default: true
    field :priority, :integer, default: 100

    timestamps(type: :utc_datetime)
  end

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(provider, attrs) do
    provider
    |> cast(attrs, [:name, :type, :tier, :host, :model, :api_key, :daily_limit, :headers, :enabled, :priority])
    |> validate_required([:name, :type, :tier, :model])
    |> validate_inclusion(:tier, @allowed_tiers)
    |> validate_inclusion(:type, @allowed_types)
    |> validate_number(:priority, greater_than_or_equal_to: 0)
    |> unique_constraint(:name)
  end
end
