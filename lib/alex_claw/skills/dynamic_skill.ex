defmodule AlexClaw.Skills.DynamicSkill do
  @moduledoc "Ecto schema for dynamically loaded skill plugins."
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @origins ~w(upload generated)
  @approvals ~w(totp containment)

  schema "dynamic_skills" do
    field(:name, :string)
    field(:module_name, :string)
    field(:file_path, :string)
    field(:permissions, {:array, :string}, default: [])
    field(:routes, {:array, :string}, default: [])
    field(:checksum, :string)
    field(:enabled, :boolean, default: true)

    # How the skill arrived, and what authorised loading it.
    # origin: "upload" (a human put the file there) | "generated" (an LLM wrote it)
    # approval: "totp" (a code was verified) | "containment" (CallPolicy vouched for it)
    field(:origin, :string, default: "upload")
    field(:approval, :string, default: "totp")

    timestamps(type: :utc_datetime)
  end

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(skill, attrs) do
    skill
    |> cast(attrs, [
      :name,
      :module_name,
      :file_path,
      :permissions,
      :routes,
      :checksum,
      :enabled,
      :origin,
      :approval
    ])
    |> validate_required([:name, :module_name, :file_path, :checksum])
    |> validate_inclusion(:origin, @origins)
    |> validate_inclusion(:approval, @approvals)
    |> unique_constraint(:name)
    |> unique_constraint(:module_name)
  end
end
