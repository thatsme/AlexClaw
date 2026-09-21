defmodule AlexClaw.Repo.Migrations.AuditLogTextColumns do
  use Ecto.Migration

  # Every text column of the audit log was varchar(255). A longer value failed
  # the insert, and the row — the record of something that had already
  # happened — was lost. In PostgreSQL varchar to text changes no stored data
  # and does not rewrite the table.
  #
  # Rolling back fails once any value is longer than 255 characters. That is
  # the intended answer: going back would mean truncating audit rows.
  @columns ~w(caller caller_type permission decision reason principal requested_by approved_by)a

  def change do
    alter table(:auth_audit_log) do
      for column <- @columns do
        modify(column, :text, from: :string)
      end
    end
  end
end
