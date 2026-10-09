defmodule AlexClaw.Repo.Migrations.CreateDbConnections do
  @moduledoc """
  Database connections defined in the admin UI (SQL read): where a
  `sql_query` step's server is and how to reach it. The password is a secret
  in OpenBao, bound to `connection:<name>`; `credentials` holds only its
  reference, `%{"password" => %{"secret" => name}}`. The name is that
  binding, so it is unique and never changes. `tls_mode` has no default: it
  is chosen when the connection is defined.
  """
  use Ecto.Migration

  def change do
    create table(:db_connections) do
      add(:name, :string, null: false)
      add(:host, :string, null: false)
      add(:port, :integer, null: false)
      add(:database, :string, null: false)
      add(:username, :string, null: false)
      add(:tls_mode, :string, null: false)
      add(:credentials, :map, null: false, default: %{})

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:db_connections, [:name]))
  end
end
