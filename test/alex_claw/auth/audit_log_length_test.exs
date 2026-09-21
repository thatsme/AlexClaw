defmodule AlexClaw.Auth.AuditLogLengthTest do
  @moduledoc """
  Audit text is stored whole, whatever its length. The columns were once
  varchar(255): a longer reason failed the insert, and the row was lost.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.{AuditEntry, AuditLog, AuthContext}

  @long String.duplicate("é—a0", 2_500)

  defp stored(reason) do
    Repo.one!(from(e in AuditEntry, where: e.reason == ^reason, select: e))
  end

  test "a 10,000-character reason is stored and read back intact" do
    assert String.length(@long) == 10_000

    assert AuditLog.log_admin_write("fp-long", @long) == :ok
    assert stored(@long).reason == @long
  end

  test "a long caller is stored intact" do
    ctx = %AuthContext{
      caller: String.duplicate("Caller", 1_000),
      caller_type: :skill,
      permission: :llm,
      workflow_run_id: nil,
      chain_depth: 0,
      timestamp: DateTime.utc_now(),
      token: nil
    }

    reason = "long caller " <> String.duplicate("x", 300)
    assert AuditLog.log_deny(ctx, reason) == :ok

    # Compared with the literal, not with inspect/1, which truncates the same
    # way the old code did and would agree with it.
    assert stored(reason).caller == ~s(") <> String.duplicate("Caller", 1_000) <> ~s(")
  end

  test "every text column of the table is unbounded" do
    %{rows: rows} =
      Repo.query!("""
      SELECT column_name, data_type FROM information_schema.columns
      WHERE table_name = 'auth_audit_log' AND data_type IN ('character varying', 'character')
      """)

    assert rows == []
  end
end
