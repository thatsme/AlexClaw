defmodule AlexClaw.Auth.AuditEntry do
  @moduledoc "Ecto schema for persisted authorization audit log entries."
  use Ecto.Schema

  schema "auth_audit_log" do
    field :caller, :string
    field :caller_type, :string
    field :permission, :string
    field :decision, :string
    field :reason, :string
    field :workflow_run_id, :integer
    field :chain_depth, :integer, default: 0

    field :inserted_at, :utc_datetime
  end
end
