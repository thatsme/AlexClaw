defmodule AlexClaw.ResetSecondFactorTest do
  @moduledoc """
  The way back in when the authenticator AND every recovery code are lost:
  `make reset-2fa` on the host runs `AlexClaw.Release.reset_second_factor/0`
  inside the running node (architect's review of SECURITY.md, "If
  everything is lost").

  Only someone with a shell on the host — who can already read the database
  and OpenBao's volumes — can run it: it is not reachable from the admin UI,
  a chat, MCP or a skill. It turns 2FA off, deletes the admin's TOTP key in
  OpenBao, wipes every recovery code, writes an audit row, and prints a
  warning saying what it did and that 2FA must be set up again.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :vault

  import ExUnit.CaptureIO
  import Ecto.Query, only: [from: 2]

  alias AlexClaw.Auth.{AuditEntry, CodeAttempts, RecoveryCodes, TOTP}
  alias AlexClaw.Release

  setup do
    CodeAttempts.reset()
    on_exit(&CodeAttempts.reset/0)
    {:ok, %{secret: secret}} = TOTP.setup()

    :ok =
      TOTP.confirm_setup(NimbleTOTP.verification_code(secret, time: System.os_time(:second) - 30))

    codes = RecoveryCodes.generate()
    assert TOTP.enabled?()
    %{secret: secret, codes: codes}
  end

  test "turns the second factor off, removes its key and codes, and says so", %{codes: [code | _]} do
    output = capture_io(fn -> assert :ok = Release.reset_second_factor() end)

    refute TOTP.enabled?()
    refute TOTP.key_recorded?()
    assert RecoveryCodes.remaining() == 0
    refute RecoveryCodes.valid?(code)

    assert output =~ "WARNING"
    assert output =~ ~r/second factor.*off/i
    assert output =~ ~r/set.*up again/i
  end

  test "writes an audit row" do
    capture_io(fn -> Release.reset_second_factor() end)
    AlexClaw.TaskDrain.drain()

    assert [row] =
             Repo.all(
               from(e in AuditEntry, where: e.permission == "control_plane.reset_second_factor")
             )

    assert row.caller_type == "operator"
  end

  test "a new second factor can be set up afterwards" do
    capture_io(fn -> Release.reset_second_factor() end)

    assert {:ok, %{secret: _}} = TOTP.setup()
  end

  test "is reachable from no entry point but the host" do
    refute Map.has_key?(AlexClaw.ControlPlane.catalogue(), :reset_second_factor)
  end
end
