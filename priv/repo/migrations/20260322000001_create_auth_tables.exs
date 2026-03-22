defmodule AlexClaw.Repo.Migrations.CreateAuthTables do
  use Ecto.Migration

  def change do
    create table(:auth_policies) do
      add :name, :string, null: false
      add :description, :text
      add :rule_type, :string, null: false
      add :config, :map, null: false, default: %{}
      add :enabled, :boolean, default: true
      add :priority, :integer, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:auth_policies, [:enabled])
    create index(:auth_policies, [:rule_type])

    create table(:auth_audit_log) do
      add :caller, :string, null: false
      add :caller_type, :string, null: false
      add :permission, :string, null: false
      add :decision, :string, null: false
      add :reason, :string
      add :workflow_run_id, :integer
      add :chain_depth, :integer, default: 0

      add :inserted_at, :utc_datetime, null: false
    end

    create index(:auth_audit_log, [:inserted_at])
    create index(:auth_audit_log, [:decision])
    create index(:auth_audit_log, [:caller])
  end
end
