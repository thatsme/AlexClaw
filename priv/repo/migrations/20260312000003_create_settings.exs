defmodule AlexClaw.Repo.Migrations.CreateSettings do
  use Ecto.Migration

  def change do
    create table(:settings) do
      add :key, :string, null: false
      add :value, :text, null: false
      add :type, :string, null: false, default: "string"
      add :description, :text
      add :category, :string, default: "general"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:settings, [:key])
    create index(:settings, [:category])
  end
end
