defmodule AlexClawWeb.SessionRevocationTriggersTest do
  @moduledoc """
  The events that end logins other than the one making them: redeeming a
  recovery code, turning 2FA off in the admin UI (with an authenticator code
  or, for a lost phone, a recovery code), and "Sign out everywhere". Each is
  audited; the last is a gated change. Since 0.4.0 a gateway cannot turn 2FA
  off at all.

  Driven through the paths an operator uses, not the store's own functions.
  """
  use AlexClawWeb.ConnCase, async: false
  @moduletag :integration

  import Ecto.Query

  alias AlexClaw.Auth.{
    AuditEntry,
    CodeAttempts,
    CodeEntry,
    Elevation,
    RecoveryCodes,
    Sessions,
    TOTP
  }

  alias AlexClaw.{Config, Dispatcher, Message, Repo}

  setup do
    secret = NimbleTOTP.secret()

    Config.set("auth.totp.secret", Base.encode32(secret, padding: false),
      type: "string",
      category: "auth"
    )

    Config.set("auth.totp.enabled", "true", type: "boolean", category: "auth")
    Config.delete("auth.totp.last_used_at")
    CodeAttempts.reset()

    {:ok, secret: secret}
  end

  defp opened do
    s = Elevation.new_sid()
    :ok = Sessions.open(s)
    s
  end

  defp audited?(decision, fragment) do
    Repo.exists?(
      from(e in AuditEntry, where: e.decision == ^decision and like(e.reason, ^"%#{fragment}%"))
    )
  end

  test "redeeming a recovery code ends every other login" do
    [code | _] = RecoveryCodes.generate()
    [keep, other] = [opened(), opened()]

    assert CodeEntry.verify(keep, code, :web) == :ok

    assert Sessions.valid?(keep)
    refute Sessions.valid?(other)
    assert audited?("outcome", "signed out: recovery code redeemed")
  end

  test "an authenticator code ends nothing", %{secret: secret} do
    [keep, other] = [opened(), opened()]

    assert CodeEntry.verify(keep, NimbleTOTP.verification_code(secret), :web) == :ok

    assert Sessions.valid?(other)
  end

  test "turning 2FA off in the admin UI ends every other login", %{conn: conn, secret: secret} do
    keep = Elevation.new_sid()
    other = opened()
    {:ok, view, _html} = conn |> authenticate(keep) |> live("/services")

    render_submit(view, "disable_2fa", %{"code" => NimbleTOTP.verification_code(secret)})

    refute TOTP.enabled?()
    assert Sessions.valid?(keep)
    refute Sessions.valid?(other)
    assert audited?("outcome", "signed out: two-factor authentication disabled")
  end

  # The lost-phone path: a recovery code turns 2FA off, once. Without it, a
  # lost authenticator would lock the admin out for good.
  test "turning 2FA off in the admin UI with a recovery code works, once", %{conn: conn} do
    [code | _] = RecoveryCodes.generate()
    keep = Elevation.new_sid()
    other = opened()
    {:ok, view, _html} = conn |> authenticate(keep) |> live("/services")

    render_submit(view, "disable_2fa", %{"code" => code})

    refute TOTP.enabled?()
    refute Sessions.valid?(other)
    assert audited?("outcome", "signed out: two-factor authentication disabled")
    # Recorded as a recovery-code use, not as an authenticator code: after a
    # lost phone, that is the first thing an incident review looks for.
    assert audited?("outcome", "recovery code")
  end

  # Since 0.4.0 the second factor is managed only in the admin UI: the
  # gateway command is refused, whatever the code, and ends nothing.
  test "turning 2FA off from a gateway is refused, and ends no login", %{secret: secret} do
    [a, b] = [opened(), opened()]

    Dispatcher.dispatch(%Message{
      text: "/disable 2fa " <> NimbleTOTP.verification_code(secret),
      chat_id: "123",
      from: "Test",
      timestamp: DateTime.utc_now(),
      raw: %{},
      gateway: :test
    })

    assert TOTP.enabled?()
    assert Sessions.valid?(a)
    assert Sessions.valid?(b)
  end

  describe "Sign out everywhere" do
    test "ends every login, this one included, and is audited", %{conn: conn} do
      me = Elevation.new_sid()
      other = opened()
      {:ok, view, _html} = conn |> authenticate(me) |> live("/services")
      {:ok, _} = Elevation.grant(me)
      on_exit(fn -> AlexClaw.SandboxCleanup.run(fn -> Elevation.revoke(me) end) end)

      assert {:error, {:redirect, %{to: "/login"}}} = render_click(view, "sign_out_everywhere")

      refute Sessions.valid?(me)
      refute Sessions.valid?(other)
      assert audited?("write", "all admin sessions signed out")
    end

    test "is refused without an elevation, and every login stays", %{conn: conn} do
      me = Elevation.new_sid()
      other = opened()
      {:ok, view, _html} = conn |> authenticate(me) |> live("/services")

      render_click(view, "sign_out_everywhere")

      assert Sessions.valid?(me)
      assert Sessions.valid?(other)
      assert audited?("deny", "all admin sessions signed out")
    end
  end
end
