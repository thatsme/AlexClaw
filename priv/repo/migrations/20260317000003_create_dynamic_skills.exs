defmodule AlexClaw.Repo.Migrations.CreateDynamicSkills do
  use Ecto.Migration

  def change do
    create table(:dynamic_skills) do
      add :name, :string, null: false
      add :module_name, :string, null: false
      add :file_path, :string, null: false
      add :permissions, {:array, :string}, default: []
      add :checksum, :string, null: false
      add :enabled, :boolean, default: true, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:dynamic_skills, [:name])
    create unique_index(:dynamic_skills, [:module_name])
  end
end
