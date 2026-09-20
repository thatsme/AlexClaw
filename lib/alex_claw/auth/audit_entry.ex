defmodule AlexClaw.Auth.AuditEntry do
  @moduledoc "Ecto schema for persisted authorization audit log entries."
  use Ecto.Schema

  schema "auth_audit_log" do
    field(:caller, :string)
    field(:caller_type, :string)
    field(:permission, :string)
    field(:decision, :string)
    field(:reason, :string)
    field(:workflow_run_id, :integer)
    field(:chain_depth, :integer, default: 0)

    field(:inserted_at, :utc_datetime)
  end

  @fields ~w(caller caller_type permission decision reason workflow_run_id chain_depth inserted_at)a
  @required ~w(caller caller_type permission decision inserted_at)a

  @type t :: %__MODULE__{}

  @doc "Changeset for an audit row. Every field is written by the logger, never by a user."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(entry, attrs) do
    entry
    |> Ecto.Changeset.cast(attrs, @fields)
    |> Ecto.Changeset.validate_required(@required)
  end
end
