defmodule AlexClaw.Auth.TotpOrphanedFlagTest do
  @moduledoc """
  A flag without a secret is not a configured second factor.

  `auth.totp.enabled = true` with nothing stored behind it describes an
  instance that reports 2FA as on, refuses every code because there is nothing
  to compare against, and hides the setup button because the page asks the same
  question — a control plane that is read-only with no way out from the
  browser.

  It is not hypothetical. An instance upgraded from 0.3.21 arrived in exactly
  this state and had to be cleared by hand, because `configured?/0` returned
  the flag and never looked for a secret.

  The page is asserted here as rendered output, not as a reachable handler.
  `handle_event("setup_2fa", ...)` was ungated and correct throughout — and the
  button that reaches it was never drawn, which is a dead end that reading the
  handler cannot show.
  """
  use AlexClawWeb.ConnCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.{Elevation, SecondFactor, TOTP}
  alias AlexClaw.Config

  setup do
    sid = Elevation.new_sid()

    Config.delete("auth.totp.secret")
    Config.delete("auth.totp.pending_secret")
    Config.set("auth.totp.enabled", "false", type: "boolean", category: "auth")

    on_exit(fn -> AlexClaw.SandboxCleanup.run(fn -> Elevation.revoke(sid) end) end)

    {:ok, sid: sid}
  end

  defp orphan_the_flag do
    Config.set("auth.totp.enabled", "true", type: "boolean", category: "auth")
    Config.delete("auth.totp.secret")
  end

  defp enrol do
    secret = NimbleTOTP.secret()

    Config.set("auth.totp.secret", Base.encode32(secret, padding: false),
      type: "string",
      category: "auth",
      sensitive: true
    )

    Config.set("auth.totp.enabled", "true", type: "boolean", category: "auth")
    secret
  end

  defp open(conn, sid) do
    {:ok, _view, html} =
      conn
      |> authenticate(sid)
      |> live("/services")

    html
  end

  describe "configured?/0 with the flag on and no secret" do
    test "is false, because nothing can answer a code" do
      orphan_the_flag()

      assert AlexClaw.Config.enabled?("auth.totp.enabled"),
             "the flag is the precondition for this test"

      refute TOTP.configured?()
      refute SecondFactor.impl().configured?()
      refute Elevation.configured?()
    end

    test "is true once a secret is stored" do
      enrol()

      assert TOTP.configured?()
      assert Elevation.configured?()
    end

    test "is false when a secret exists but the flag is off" do
      enrol()
      Config.set("auth.totp.enabled", "false", type: "boolean", category: "auth")

      refute TOTP.configured?()
    end
  end

  describe "the rendered services page" do
    test "offers Set up 2FA when the flag is on but no secret is stored", %{conn: conn, sid: sid} do
      orphan_the_flag()

      html = open(conn, sid)

      assert html =~ "setup_2fa",
             "no way to enrol: the flag says configured, so the button is not drawn"

      refute html =~ "Turn 2FA off",
             "offering to turn off a second factor that cannot verify a code is a dead end"
    end

    test "offers Turn 2FA off once a secret is stored", %{conn: conn, sid: sid} do
      enrol()

      html = open(conn, sid)

      assert html =~ "Turn 2FA off"
      refute html =~ "setup_2fa"
    end
  end

  describe "the control plane" do
    test "stays read-only while the flag is on and no secret is stored", %{sid: sid} do
      orphan_the_flag()

      refute Elevation.elevated?(sid),
             "an orphaned flag must not be mistaken for an elevation"

      refute Elevation.configured?(),
             "and the instance must not claim it can elevate"
    end
  end

  # The migration normalises the rows that exist today. This is what catches a
  # state that appears afterwards — a secret deleted, or one that stops
  # decrypting — and it runs fifteen seconds into every boot.
  describe "the boot check" do
    test "says an enabled factor has no secret behind it" do
      orphan_the_flag()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(Process.whereis(AlexClaw.Config.Loader), :report_second_factor)
          Process.sleep(200)
        end)

      assert log =~ "2FA is enabled but no secret is stored"
      assert log =~ "set it up again"
    end

    # Withdrawing the flag automatically was written and then removed. "No
    # secret" and "no secret this code can see" are not the same state, nothing
    # here can tell them apart, and something that answered the first question
    # by acting on the second is what erased the secret to begin with.
    test "changes nothing while saying it" do
      orphan_the_flag()

      send(Process.whereis(AlexClaw.Config.Loader), :report_second_factor)
      Process.sleep(200)

      assert AlexClaw.Config.enabled?("auth.totp.enabled"),
             "the boot check withdrew the flag; reporting must not repair"
    end

    test "is silent for a properly configured instance" do
      enrol()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(Process.whereis(AlexClaw.Config.Loader), :report_second_factor)
          Process.sleep(200)
        end)

      refute log =~ "no secret is stored"
      assert TOTP.configured?()
    end
  end
end
