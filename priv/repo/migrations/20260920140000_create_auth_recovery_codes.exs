defmodule AlexClaw.Repo.Migrations.CreateAuthRecoveryCodes do
  use Ecto.Migration

  # The way back in when the authenticator is gone. Ten one-time codes, stored
  # as SHA-256 hashes: the value here cannot be used to log in, which is the
  # point of writing it down rather than the code.
  #
  # One row per code, so consuming one is an update on that row and "how many
  # are left" is a count. A single row holding all ten would make redemption a
  # read-modify-write, and two tabs redeeming at once would lose one.
  def change do
    create table(:auth_recovery_codes) do
      add(:hash, :string, null: false)
      add(:used_at, :utc_datetime)

      timestamps(updated_at: false, type: :utc_datetime)
    end

    # The hash is what a redemption looks up, and no two codes share one.
    create(unique_index(:auth_recovery_codes, [:hash]))
  end
end
