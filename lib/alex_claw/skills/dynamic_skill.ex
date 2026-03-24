defmodule AlexClaw.Skills.DynamicSkill do
  @moduledoc "Ecto schema for dynamically loaded skill plugins."
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "dynamic_skills" do
    field :name, :string
    field :module_name, :string
    field :file_path, :string
    field :permissions, {:array, :string}, default: []
    field :routes, {:array, :string}, default: []
    field :checksum, :string
    field :enabled, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(skill, attrs) do
    skill
    |> cast(attrs, [:name, :module_name, :file_path, :permissions, :routes, :checksum, :enabled])
    |> validate_required([:name, :module_name, :file_path, :checksum])
    |> unique_constraint(:name)
    |> unique_constraint(:module_name)
  end
end
