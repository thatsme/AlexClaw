defmodule AlexClawWeb.AdminLive.TotpTakeoverTest do
  @moduledoc """
  The password alone cannot replace an active second factor
  (reports/SECRETS_INVENTORY.md #31, #19; 0.3.56, security).

  Setting up 2FA needs only the password — adding protection is not a
  privileged act (totp_setup_test.exs). But when 2FA is already on, a new
  setup REPLACES the factor: `TOTP.setup/0` created a pending secret with no
  enabled-check, and `confirm_setup/1` overwrote the active one and
  regenerated the recovery codes. Anyone with the admin password — phished,
  shoulder-surfed — could swap in their own authenticator and walk through
  every gate. And the gateway's `/setup 2fa` sent the new secret over
  Telegram in clear.

  Now:
  - while 2FA is on, a new setup is refused — at the context, whatever path
    calls it; replacing the factor means turning it off first, which needs a
    current code;
  - the active secret and the recovery codes are untouched by any refused
    attempt;
  - 2FA is set up only in the admin UI: `/setup 2fa` on a gateway answers
    where to do it, and no secret ever travels over a chat.
  """
  use AlexClawWeb.ConnCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.{CodeAttempts, Elevation, TOTP}
  alias AlexClaw.{Dispatcher, Message, RecordingGateway}

  setup do
    CodeAttempts.reset()
    sid = Elevation.new_sid()

    AlexClaw.Config.set("auth.totp.enabled", "false", type: "boolean", category: "auth")
    AlexClaw.Config.delete("auth.totp.secret")
    AlexClaw.Config.delete("auth.totp.pending_secret")
    AlexClaw.Config.delete("auth.totp.last_used_at")

    # 2FA on, with a known secret. TOTP.setup/0 returns the raw secret bytes;
    # what is stored, and what TOTP.secret/0 returns, is its Base32 text.
    {:ok, %{secret: secret}} = TOTP.setup()
    :ok = TOTP.confirm_setup(NimbleTOTP.verification_code(secret))
    AlexClaw.Config.delete("auth.totp.last_used_at")

    on_exit(fn ->
      AlexClaw.SandboxCleanup.run(fn -> Elevation.revoke(sid) end)
      CodeAttempts.reset()
    end)

    {:ok, sid: sid, secret: secret, active: Base.encode32(secret, padding: false)}
  end

  defp open(conn, sid) do
    {:ok, view, html} =
      conn
      |> authenticate(sid)
      |> live("/services")

    {view, html}
  end

  defp send_command(text) do
    Dispatcher.dispatch(%Message{
      text: text,
      chat_id: "takeover-chat",
      from: "Test",
      timestamp: DateTime.utc_now(),
      raw: %{},
      gateway: :test
    })

    RecordingGateway.sent()
  end

  describe "the context" do
    test "a new setup is refused while 2FA is on", %{active: active} do
      assert {:error, :already_enabled} = TOTP.setup()
      assert TOTP.secret() == active
      refute AlexClaw.Config.get("auth.totp.pending_secret")
    end

    test "a confirm cannot replace the active secret", %{active: active} do
      # Even with a pending secret planted by some other path.
      planted = NimbleTOTP.secret()

      AlexClaw.Config.set("auth.totp.pending_secret", Base.encode32(planted, padding: false),
        type: "string",
        category: "auth",
        sensitive: true
      )

      assert {:error, _} = TOTP.confirm_setup(NimbleTOTP.verification_code(planted))
      assert TOTP.secret() == active
    end

    test "after turning it off with a code, a new setup is allowed", %{secret: secret} do
      # The code that confirmed the setup cannot be replayed within its
      # period; move the marker back so a fresh code is valid.
      AlexClaw.Config.set("auth.totp.last_used_at", to_string(System.os_time(:second) - 120),
        type: "string",
        category: "auth"
      )

      :ok = TOTP.disable(NimbleTOTP.verification_code(secret))

      assert {:ok, %{secret: _new}} = TOTP.setup()
    end
  end

  describe "the admin UI" do
    # The button is hidden when 2FA is on; the handler must refuse anyway —
    # a crafted event reaches it.
    test "a crafted setup event is refused, and shows no new secret", ctx do
      {view, _html} = open(ctx.conn, ctx.sid)

      html = render_click(view, "setup_2fa", %{})

      assert TOTP.secret() == ctx.active
      refute AlexClaw.Config.get("auth.totp.pending_secret")
      refute html =~ "data:image/png;base64,"
      assert html =~ ~r/already/i
    end
  end

  describe "gateways" do
    setup do
      RecordingGateway.install()
      # The owner chat (0.4.0 S5b): a gateway answers only the chat set in the
      # admin UI.
      AlexClaw.Config.set("telegram.chat_id", "takeover-chat",
        type: "string",
        category: "telegram"
      )

      :ok
    end

    test "/setup 2fa never sends a secret, and points to the admin UI" do
      sent = send_command("/setup 2fa")

      assert Enum.any?(sent, &(&1 =~ ~r/admin UI/i))
      # A base32 TOTP secret: 16+ characters of A-Z2-7.
      refute Enum.any?(sent, &(&1 =~ ~r/\b[A-Z2-7]{16,}\b/))
      refute AlexClaw.Config.get("auth.totp.pending_secret")
    end

    test "/setup 2fa leaves the active factor as it was", %{active: active} do
      send_command("/setup 2fa")
      assert TOTP.secret() == active
    end
  end
end
