defmodule AlexClaw.Skills.DynamicSkill do
  @moduledoc "Ecto schema for dynamically loaded skill plugins."
  use Ecto.Schema
  import Ecto.Changeset

  schema "dynamic_skills" do
    field :name, :string
    field :module_name, :string
    field :file_path, :string
    field :permissions, {:array, :string}, default: []
    field :checksum, :string
    field :enabled, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  def changeset(skill, attrs) do
    skill
    |> cast(attrs, [:name, :module_name, :file_path, :permissions, :checksum, :enabled])
    |> validate_required([:name, :module_name, :file_path, :checksum])
    |> unique_constraint(:name)
    |> unique_constraint(:module_name)
  end
end
