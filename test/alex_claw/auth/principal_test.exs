defmodule AlexClaw.Auth.PrincipalTest do
  @moduledoc """
  Whose authority an action ran under.

  There is one principal, and these tests exist for the day there is not. An
  audit row that answers "who approved this" only because there has never been
  anyone else stops answering it the moment there is, and by then the rows
  already written cannot be corrected.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.{AuditLog, AuthContext, CodeAttempts, Elevation, Principal, RecoveryCodes}

  setup do
    CodeAttempts.reset()
    on_exit(&CodeAttempts.reset/0)
    :ok
  end

  defp context do
    %AuthContext{caller: SomeSkill, caller_type: :dynamic, permission: :shell_exec}
  end

  defp latest(decision), do: AuditLog.recent(limit: 1, decision: decision) |> List.first()

  describe "the principal" do
    test "is the owner" do
      assert Principal.current() == "owner"
    end

    test "requests and approves as itself, for now" do
      assert Principal.requested_by() == Principal.current()
      assert Principal.approved_by() == Principal.current()
    end

    # The fields are separate so that four-eyes approval is a change in one
    # module rather than a migration across every row ever written.
    test "offers the three fields an audit row records" do
      fields = Principal.audit_fields()

      assert fields.principal == "owner"
      assert fields.requested_by == "owner"
      assert fields.approved_by == "owner"
    end
  end

  describe "audit rows" do
    test "carry the principal on a denial" do
      :ok = AuditLog.log_deny(context(), "no policy allows it")

      assert latest("deny").principal == "owner"
    end

    test "carry the principal on an admin write" do
      :ok = AuditLog.log_admin_write("fingerprint", "shell.whitelist: 'a' → 'b'")

      row = latest("write")
      assert row.principal == "owner"
      assert row.requested_by == "owner"
      assert row.approved_by == "owner"
    end

    test "carry the principal on a refusal" do
      :ok = AuditLog.log_admin_refusal("fingerprint", :no_second_factor, "config save")

      assert latest("deny").principal == "owner"
    end

    test "carry the principal on a second-factor attempt" do
      :ok = AuditLog.log_code_attempt(:refused, "fingerprint", :web, :unknown)

      assert latest("refused").principal == "owner"
    end

    test "carry the principal when recovery codes are generated" do
      RecoveryCodes.generate()

      assert latest("generated").principal == "owner"
      RecoveryCodes.discard()
    end
  end

  describe "an elevation" do
    test "records the principal it was granted under" do
      sid = Elevation.new_sid()
      {:ok, _expires_at} = Elevation.grant(sid)

      row = AuditLog.recent(limit: 5, decision: "granted") |> List.first()

      assert row.principal == "owner"
      assert row.reason =~ "principal: owner"

      Elevation.revoke(sid)
    end
  end

  describe "a gate request" do
    test "carries who asked for it" do
      action = %{type: :run_workflow, workflow_id: 1, requested_by: Principal.requested_by()}

      assert action.requested_by == "owner"
    end
  end
end
