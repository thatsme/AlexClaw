defmodule AlexClaw.Repo.Migrations.CreateClusterNodes do
  use Ecto.Migration

  def change do
    create table(:cluster_nodes) do
      add :name, :string, null: false
      add :label, :string
      add :status, :string, default: "unknown"
      add :last_seen_at, :utc_datetime
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:cluster_nodes, [:name])
  end
end
