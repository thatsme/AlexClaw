defmodule AlexClaw.Repo.Migrations.CreateResources do
  use Ecto.Migration

  def change do
    create table(:resources) do
      add :name, :string, null: false
      add :type, :string, null: false
      add :url, :string
      add :content, :text
      add :metadata, :map, default: %{}
      add :tags, {:array, :string}, default: []
      add :enabled, :boolean, default: true

      timestamps()
    end

    create index(:resources, [:type])
    create index(:resources, [:enabled])
  end
end
