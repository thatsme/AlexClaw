defmodule AlexClaw.LLM.Provider do
  @moduledoc "Schema for custom LLM provider configurations."

  use Ecto.Schema
  import Ecto.Changeset

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

    timestamps(type: :utc_datetime)
  end

  def changeset(provider, attrs) do
    provider
    |> cast(attrs, [:name, :type, :tier, :host, :model, :api_key, :daily_limit, :headers, :enabled])
    |> validate_required([:name, :type, :tier, :host, :model])
    |> validate_inclusion(:tier, @allowed_tiers)
    |> validate_inclusion(:type, @allowed_types)
    |> unique_constraint(:name)
  end
end
