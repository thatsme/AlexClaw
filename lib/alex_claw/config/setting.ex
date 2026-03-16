defmodule AlexClaw.Config.Setting do
  @moduledoc "Schema for key-value configuration settings stored in the database."

  use Ecto.Schema
  import Ecto.Changeset

  schema "settings" do
    field :key, :string
    field :value, :string, default: ""
    field :type, :string, default: "string"
    field :description, :string
    field :category, :string, default: "general"

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{
          id: integer() | nil,
          key: String.t(),
          value: String.t(),
          type: String.t(),
          description: String.t() | nil,
          category: String.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:key, :value, :type, :description, :category])
    |> validate_required([:key, :type])
    |> validate_inclusion(:type, ~w(string integer float boolean json))
    |> unique_constraint(:key)
  end
end
