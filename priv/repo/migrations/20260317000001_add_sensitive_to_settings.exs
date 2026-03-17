defmodule AlexClaw.Repo.Migrations.AddSensitiveToSettings do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      add :sensitive, :boolean, default: false, null: false
    end
  end
end
