defmodule AlexClaw.Auth.AuditRefusalsTest do
  @moduledoc """
  Every refusal writes its row, and a refusal never crashes the door (S9 fix
  review, M4 ruling; THREAT_MODEL P8).

  - A change that fails with a reason that is not text (a tuple) is refused
    with that reason and recorded; the reason is written as text.
  - A change approved with a code that is then undone — its own row could not
    be written, or the action failed — leaves a refusal row after the
    rollback.
  - A refusal row is written even when the text it quotes could not be
    stored as it is.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :vault

  alias AlexClaw.Auth.{AuditEntry, Elevation, TOTP}
  alias AlexClaw.ControlPlane
  alias AlexClaw.ControlPlane.Context

  defp rows(action) do
    AlexClaw.TaskDrain.drain()

    Repo.all(
      from(e in AuditEntry,
        where: e.permission == ^"control_plane.#{action}" and e.decision == "deny"
      )
    )
  end

  setup do
    sid = Elevation.new_sid()
    on_exit(fn -> AlexClaw.SandboxCleanup.run(fn -> Elevation.revoke(sid) end) end)
    %{sid: sid}
  end

  test "a change failing with a tuple is refused with it, and recorded", %{sid: sid} do
    AlexClaw.Config.set("auth.totp.enabled", "true", type: "boolean", category: "auth")
    {:ok, _} = Elevation.grant(sid)

    assert {:error, {:import_failed, _message}} =
             ControlPlane.perform(:import_workflow, %{data: "not json"}, Context.admin_ui(sid))

    assert [row] = rows(:import_workflow)
    assert row.reason =~ "import_failed"
  end

  test "a change approved with a code and then undone leaves a refusal row", %{sid: sid} do
    {:ok, %{secret: secret}} = TOTP.setup()

    :ok =
      TOTP.confirm_setup(NimbleTOTP.verification_code(secret, time: System.os_time(:second) - 30))

    # Its own row cannot be written: PostgreSQL refuses a NUL in text.
    params = %{key: "undone\u0000"}

    assert {:error, :audit_failed} =
             ControlPlane.perform(
               :regenerate_recovery_codes,
               params,
               Context.admin_ui(sid, NimbleTOTP.verification_code(secret))
             )

    assert [row] = rows(:regenerate_recovery_codes)
    assert row.reason =~ "audit_failed"
  end
end
