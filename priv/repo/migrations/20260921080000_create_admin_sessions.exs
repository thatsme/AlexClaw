defmodule AlexClaw.Repo.Migrations.CreateAdminSessions do
  use Ecto.Migration

  # Live admin logins, on the server, where every node sees them. The token is
  # never stored: only its SHA-256, so reading the table yields nothing that
  # signs anyone in. The password fingerprint is a keyed hash of the admin
  # password the login was made with — keyed, because a plain hash of the
  # password would be an offline-crackable copy of it.
  def change do
    create table(:admin_sessions) do
      add(:token_hash, :binary, null: false)
      add(:password_fingerprint, :binary, null: false)
      add(:inserted_at, :utc_datetime, null: false)
    end

    create(unique_index(:admin_sessions, [:token_hash]))
    create(index(:admin_sessions, [:inserted_at]))
  end
end
