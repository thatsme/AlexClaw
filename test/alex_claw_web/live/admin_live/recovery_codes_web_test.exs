defmodule AlexClawWeb.AdminLive.RecoveryCodesWebTest do
  @moduledoc """
  Recovery codes where an operator meets them.

  Shown once, in the browser, and never anywhere else — a chat log is not where
  the way back in belongs. Accepted afterwards in every field that takes a
  code, because the operator reaching for one has lost the thing that would
  have told them which field to use.
  """
  use AlexClawWeb.ConnCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.{CodeAttempts, Elevation, RecoveryCodes, TOTP}
  alias AlexClaw.RecordingGateway

  setup do
    CodeAttempts.reset()
    RecoveryCodes.discard()
    sid = Elevation.new_sid()

    AlexClaw.Config.set("auth.totp.enabled", "false", type: "boolean", category: "auth")
    AlexClaw.Config.delete("auth.totp.secret")
    AlexClaw.Config.delete("auth.totp.pending_secret")
    AlexClaw.Config.delete("auth.totp.last_used_at")

    on_exit(fn ->
      AlexClaw.SandboxCleanup.run(fn -> Elevation.revoke(sid) end)
      CodeAttempts.reset()
      RecoveryCodes.discard()
    end)

    {:ok, sid: sid}
  end

  defp open(conn, sid, page \\ "/services") do
    {:ok, view, html} =
      conn
      |> authenticate(sid)
      |> live(page)

    {view, html}
  end

  defp pending_code do
    "auth.totp.pending_secret"
    |> AlexClaw.Config.get()
    |> Base.decode32!(padding: false)
    |> NimbleTOTP.verification_code()
  end

  defp enable_2fa_in_ui(conn, sid) do
    {view, _html} = open(conn, sid)
    render_click(view, "setup_2fa", %{})
    html = render_submit(view, "confirm_2fa", %{"code" => pending_code()})
    AlexClaw.Config.delete("auth.totp.last_used_at")

    {view, html}
  end

  describe "enabling 2FA in the UI" do
    test "produces a set of codes and shows them", ctx do
      {_view, html} = enable_2fa_in_ui(ctx.conn, ctx.sid)

      assert TOTP.enabled?()
      assert RecoveryCodes.remaining() == RecoveryCodes.count()
      assert html =~ "Save these recovery codes now"
    end

    test "shows every code exactly once", ctx do
      {_view, html} = enable_2fa_in_ui(ctx.conn, ctx.sid)

      # Ten code-shaped strings on the page, and each appears once.
      shown = Regex.scan(~r/\b[0-9A-Z]{5}-[0-9A-Z]{5}\b/, html) |> List.flatten()

      assert length(shown) == RecoveryCodes.count()
      assert length(Enum.uniq(shown)) == RecoveryCodes.count()
    end

    test "acknowledging clears them from the page", ctx do
      {view, _html} = enable_2fa_in_ui(ctx.conn, ctx.sid)

      html = render_click(view, "saved_recovery_codes", %{})

      refute html =~ "Save these recovery codes now"
      refute html =~ ~r/\b[0-9A-Z]{5}-[0-9A-Z]{5}\b/
    end

    # The claim this test exists for: the codes are the way back in, and a
    # gateway is a place an attacker may already be reading.
    test "sends no code over any gateway", ctx do
      RecordingGateway.install()

      enable_2fa_in_ui(ctx.conn, ctx.sid)
      codes = sent_messages()

      for message <- codes do
        refute message =~ ~r/\b[0-9A-Z]{5}-[0-9A-Z]{5}\b/,
               "a recovery code left the instance over a gateway: #{message}"
      end
    end
  end

  describe "a recovery code in a code field" do
    setup ctx do
      {:ok, %{secret: secret}} = TOTP.setup()
      :ok = TOTP.confirm_setup(NimbleTOTP.verification_code(secret))
      AlexClaw.Config.delete("auth.totp.last_used_at")

      {:ok, codes: RecoveryCodes.generate()}
    end

    test "elevates a session", ctx do
      {view, _html} = open(ctx.conn, ctx.sid, "/config")
      render_click(view, "unlock_editing", %{})

      render_submit(view, "submit_code", %{"code" => hd(ctx.codes)})

      assert Elevation.elevated?(ctx.sid)
    end

    test "works exactly once", ctx do
      code = hd(ctx.codes)
      {view, _html} = open(ctx.conn, ctx.sid, "/config")
      render_click(view, "unlock_editing", %{})
      render_submit(view, "submit_code", %{"code" => code})
      :ok = Elevation.revoke(ctx.sid)

      render_submit(view, "submit_code", %{"code" => code})

      refute Elevation.elevated?(ctx.sid),
             "a spent recovery code elevated a session a second time"
    end

    test "is announced over a gateway, without the code itself", ctx do
      RecordingGateway.install()
      {view, _html} = open(ctx.conn, ctx.sid, "/config")
      render_click(view, "unlock_editing", %{})

      render_submit(view, "submit_code", %{"code" => hd(ctx.codes)})

      messages = sent_messages()
      assert Enum.any?(messages, &(&1 =~ "recovery code was used"))

      for message <- messages do
        refute message =~ hd(ctx.codes)
      end
    end

    test "counts down, and the page says how many are left", ctx do
      {view, _html} = open(ctx.conn, ctx.sid, "/config")
      render_click(view, "unlock_editing", %{})
      render_submit(view, "submit_code", %{"code" => hd(ctx.codes)})

      {_services, html} = open(ctx.conn, ctx.sid)

      assert RecoveryCodes.remaining() == RecoveryCodes.count() - 1
      assert html =~ "A recovery code was used on"
    end

    test "warns persistently once two are left", ctx do
      for code <- Enum.take(ctx.codes, RecoveryCodes.count() - 2) do
        {:ok, _remaining} = RecoveryCodes.redeem(code)
      end

      {_view, html} = open(ctx.conn, ctx.sid)

      assert html =~ "Only 2 recovery codes left"
    end
  end

  describe "regenerating" do
    setup ctx do
      {:ok, %{secret: secret}} = TOTP.setup()
      :ok = TOTP.confirm_setup(NimbleTOTP.verification_code(secret))
      AlexClaw.Config.delete("auth.totp.last_used_at")

      {:ok, codes: RecoveryCodes.generate(), secret: secret}
    end

    test "needs a current code", ctx do
      {view, _html} = open(ctx.conn, ctx.sid)

      render_submit(view, "regenerate_recovery_codes", %{"code" => "000000"})

      assert {:error, :invalid_code} != RecoveryCodes.redeem(hd(ctx.codes)),
             "the old codes were replaced without a valid code"
    end

    test "invalidates the old set", ctx do
      old = hd(ctx.codes)
      {view, _html} = open(ctx.conn, ctx.sid)

      render_submit(view, "regenerate_recovery_codes", %{
        "code" => NimbleTOTP.verification_code(ctx.secret)
      })

      assert {:error, :invalid_code} = RecoveryCodes.redeem(old)
      assert RecoveryCodes.remaining() == RecoveryCodes.count()
    end

    test "shows the new set once", ctx do
      {view, _html} = open(ctx.conn, ctx.sid)

      html =
        render_submit(view, "regenerate_recovery_codes", %{
          "code" => NimbleTOTP.verification_code(ctx.secret)
        })

      assert html =~ "Save these recovery codes now"
    end
  end

  describe "turning 2FA off" do
    test "discards the codes, because they unlock nothing now", ctx do
      {:ok, %{secret: secret}} = TOTP.setup()
      :ok = TOTP.confirm_setup(NimbleTOTP.verification_code(secret))
      AlexClaw.Config.delete("auth.totp.last_used_at")
      codes = RecoveryCodes.generate()

      {view, _html} = open(ctx.conn, ctx.sid)
      render_submit(view, "disable_2fa", %{"code" => NimbleTOTP.verification_code(secret)})

      refute TOTP.enabled?()
      refute RecoveryCodes.generated?()
      assert {:error, :invalid_code} = RecoveryCodes.redeem(hd(codes))
    end
  end

  defp sent_messages, do: RecordingGateway.sent()
end
