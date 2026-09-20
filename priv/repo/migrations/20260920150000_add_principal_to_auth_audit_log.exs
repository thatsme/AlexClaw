defmodule AlexClaw.Repo.Migrations.AddPrincipalToAuthAuditLog do
  use Ecto.Migration

  # Who the action was for, as distinct from what made the call. `caller` says
  # "a dynamic skill" or "an admin session"; `principal` says whose authority
  # it ran under.
  #
  # There is one principal today and the default says so. The column exists
  # because the question "who approved this" has to be answerable from the row
  # rather than from the fact that there has only ever been one person — and
  # because backfilling it later would mean inventing an answer for every row
  # already written.
  def change do
    alter table(:auth_audit_log) do
      add(:principal, :string, null: false, default: "owner")
      add(:requested_by, :string)
      add(:approved_by, :string)
    end

    create(index(:auth_audit_log, [:principal]))
  end
end
