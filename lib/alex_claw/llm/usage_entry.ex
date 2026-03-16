defmodule AlexClaw.LLM.UsageEntry do
  @moduledoc "Schema for persisted LLM usage counters."
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: integer() | nil,
          model: String.t(),
          date: Date.t(),
          count: integer()
        }

  schema "llm_usage" do
    field :model, :string
    field :date, :date
    field :count, :integer, default: 0
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:model, :date, :count])
    |> validate_required([:model, :date, :count])
    |> unique_constraint([:model, :date])
  end
end
