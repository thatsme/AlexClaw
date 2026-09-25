defmodule AlexClaw.LLM.Provider do
  @moduledoc """
  Schema for LLM provider configurations (all providers live in DB).

  A provider's API key and header values are secrets in OpenBao, bound to the
  host its calls go to (`AlexClaw.LLM.ProviderSecrets`); `credentials` holds
  the references. `api_key` and `headers` are what a save is given, planned
  into references before the row is written: they are never stored. The
  columns of those names hold only what 0.3.x left, until the boot upgrade
  moves it, and are not mapped here.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @allowed_tiers ~w(light medium heavy local)
  @allowed_types ~w(openai_compatible ollama gemini anthropic custom)

  schema "llm_providers" do
    field(:name, :string)
    field(:type, :string, default: "openai_compatible")
    field(:tier, :string)
    field(:host, :string)
    field(:model, :string)
    field(:api_key, :string, virtual: true)
    field(:daily_limit, :integer)
    field(:headers, :map, virtual: true)
    field(:credentials, :map, default: %{})
    field(:enabled, :boolean, default: true)
    field(:priority, :integer, default: 100)
    field(:options, :map, default: %{})

    timestamps(type: :utc_datetime)
  end

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(provider, attrs) do
    provider
    |> cast(attrs, [
      :name,
      :type,
      :tier,
      :host,
      :model,
      :api_key,
      :daily_limit,
      :headers,
      :enabled,
      :priority,
      :options
    ])
    |> validate_required([:name, :type, :tier, :model])
    |> validate_inclusion(:tier, @allowed_tiers)
    |> validate_inclusion(:type, @allowed_types)
    |> validate_number(:priority, greater_than_or_equal_to: 0)
    |> unique_constraint(:name)
  end
end
