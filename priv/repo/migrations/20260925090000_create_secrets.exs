defmodule AlexClaw.Repo.Migrations.CreateSecrets do
  @moduledoc """
  The secrets catalogue: what each secret is and where it may be used. There is
  no value column, by design: every value lives in OpenBao
  (`secret/alexclaw/secrets/<name>`), and this table never holds one.
  """
  use Ecto.Migration

  def change do
    create table(:secrets) do
      add(:name, :string, null: false)
      add(:description, :text)
      add(:kind, :string, null: false)
      add(:binding, {:array, :string}, null: false)
      add(:rotated_at, :utc_datetime)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:secrets, [:name]))
  end
end
