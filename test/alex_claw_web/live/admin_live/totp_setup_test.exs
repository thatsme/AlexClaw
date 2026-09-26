defmodule AlexClawWeb.AdminLive.TotpSetupTest do
  @moduledoc """
  Setting up and tearing down 2FA from the admin UI.

  Setting it up needs the admin password and nothing more — requiring a second
  factor to configure the second factor is the circle this design exists to
  break, and adding protection is not a privileged act. Turning it off is the
  opposite case, and needs a current code even from a session that already
  holds an elevation.
  """
  use AlexClawWeb.ConnCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.{CodeAttempts, Elevation, TOTP}

  setup do
    CodeAttempts.reset()
    sid = Elevation.new_sid()

    AlexClaw.Config.set("auth.totp.enabled", "false", type: "boolean", category: "auth")
    AlexClaw.Config.delete("auth.totp.secret")
    AlexClaw.Config.delete("auth.totp.pending_secret")
    AlexClaw.Config.delete("auth.totp.last_used_at")

    on_exit(fn ->
      AlexClaw.SandboxCleanup.run(fn -> Elevation.revoke(sid) end)
      CodeAttempts.reset()
    end)

    {:ok, sid: sid}
  end

  defp open(conn, sid) do
    {:ok, view, html} =
      conn
      |> authenticate(sid)
      |> live("/services")

    {view, html}
  end

  # Since 0.4.0 (S6) OpenBao keeps the key and AlexClaw stores none of it: the
  # test reads it where the person enrolling does, the key shown by hand.
  defp pending_secret(html) do
    [_, key] = Regex.run(~r/Or enter the key by hand: <code[^>]*>([A-Z2-7]+)<\/code>/, html)
    Base.decode32!(key, padding: false)
  end

  # The previous period's code confirms the setup, so the current one is still
  # unused afterwards: OpenBao accepts a code once.
  defp pending_code(html),
    do: NimbleTOTP.verification_code(pending_secret(html), time: System.os_time(:second) - 30)

  defp active_code(secret), do: NimbleTOTP.verification_code(secret)

  describe "before 2FA exists" do
    test "the page offers to set it up", ctx do
      {_view, html} = open(ctx.conn, ctx.sid)

      assert html =~ "Two-factor authentication"
      assert html =~ "Set up 2FA"
    end

    # The password alone is enough here, which is the whole point: an instance
    # with no second factor cannot elevate, so a gated setup would be a locked
    # door with the key inside.
    test "starting setup needs no elevation", ctx do
      {view, _html} = open(ctx.conn, ctx.sid)

      html = render_click(view, "setup_2fa", %{})

      refute Elevation.elevated?(ctx.sid)
      assert html =~ "Scan this with your authenticator"
      assert html =~ "data:image/png;base64,"
    end

    test "the manual key is shown for a device without a camera", ctx do
      {view, _html} = open(ctx.conn, ctx.sid)

      html = render_click(view, "setup_2fa", %{})

      assert pending_secret(html)
    end

    test "the secret is pending, not active, until a code confirms it", ctx do
      {view, _html} = open(ctx.conn, ctx.sid)

      render_click(view, "setup_2fa", %{})

      refute TOTP.enabled?()
      assert AlexClaw.Config.get("auth.totp.pending")
      refute TOTP.configured?()
    end
  end

  describe "confirming the setup" do
    test "a correct code turns 2FA on", ctx do
      {view, _html} = open(ctx.conn, ctx.sid)
      html = render_click(view, "setup_2fa", %{})

      render_submit(view, "confirm_2fa", %{"code" => pending_code(html)})

      assert TOTP.enabled?()
    end

    test "a wrong code leaves it off and says so", ctx do
      {view, _html} = open(ctx.conn, ctx.sid)
      render_click(view, "setup_2fa", %{})

      html = render_submit(view, "confirm_2fa", %{"code" => "000000"})

      refute TOTP.enabled?()
      assert html =~ "not valid"
    end

    test "confirming without a pending setup says to start again", ctx do
      {view, _html} = open(ctx.conn, ctx.sid)

      html = render_submit(view, "confirm_2fa", %{"code" => "000000"})

      assert html =~ "start again" or html =~ "Start again"
      refute TOTP.enabled?()
    end

    test "cancelling discards the pending secret", ctx do
      {view, _html} = open(ctx.conn, ctx.sid)
      render_click(view, "setup_2fa", %{})

      render_click(view, "cancel_2fa_setup", %{})

      refute AlexClaw.Config.get("auth.totp.pending")
      refute TOTP.enabled?()
    end
  end

  describe "turning 2FA off" do
    setup ctx do
      {view, _html} = open(ctx.conn, ctx.sid)
      html = render_click(view, "setup_2fa", %{})
      render_submit(view, "confirm_2fa", %{"code" => pending_code(html)})
      AlexClaw.Config.delete("auth.totp.last_used_at")

      {:ok, view: view, secret: pending_secret(html)}
    end

    test "needs a current code", %{view: view, secret: secret} do
      assert TOTP.enabled?()

      render_submit(view, "disable_2fa", %{"code" => active_code(secret)})

      refute TOTP.enabled?()
    end

    test "refuses a wrong code and stays on", %{view: view} do
      html = render_submit(view, "disable_2fa", %{"code" => "000000"})

      assert TOTP.enabled?()
      assert html =~ "not valid"
    end

    # The case that matters: a window opened an hour of typing ago must not be
    # able to remove the factor that opened it.
    test "an elevation does not stand in for the code", ctx do
      {:ok, _expires_at} = Elevation.grant(ctx.sid)

      render_submit(ctx.view, "disable_2fa", %{"code" => "000000"})

      assert TOTP.enabled?(),
             "an elevated session turned 2FA off without a code"
    end

    test "wrong codes here count against the same limits", ctx do
      for wrong <- ~w(000000 000001 000002) do
        render_submit(ctx.view, "disable_2fa", %{"code" => wrong})
      end

      assert {:locked, :session, _until} = CodeAttempts.status(ctx.sid)
      assert TOTP.enabled?()
    end
  end

  describe "the context path" do
    # The context is what both the admin UI and any other caller use. Since
    # 0.3.56 set-up happens only in the admin UI — the gateway's /setup 2fa
    # sent the secret over the chat (totp_takeover_test.exs) — but the context
    # still enables 2FA the same way when it is off.
    test "enables 2FA when it is off", ctx do
      {:ok, %{secret: secret}} = TOTP.setup()

      assert :ok = TOTP.confirm_setup(NimbleTOTP.verification_code(secret))
      assert TOTP.enabled?()
      assert ctx.sid
    end
  end
end
