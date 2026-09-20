defmodule AlexClaw.Auth.CodeAttemptAuditTest do
  @moduledoc """
  What the audit log says about a second-factor attempt.

  Two facts, not one: where the code was typed, and what kind of code it was. A
  month later the second is the one that matters — a run of accepted TOTP codes
  is an operator working, and a recovery code among them is the authenticator
  being gone.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.{AuditLog, CodeAttempts, CodeEntry, RecoveryCodes, TOTP}

  setup do
    CodeAttempts.reset()
    RecoveryCodes.discard()
    secret = enable_totp()

    on_exit(fn ->
      CodeAttempts.reset()
      RecoveryCodes.discard()
    end)

    {:ok, secret: secret, sid: "sid-#{System.unique_integer([:positive])}"}
  end

  defp enable_totp do
    secret = NimbleTOTP.secret()

    AlexClaw.Config.set("auth.totp.secret", Base.encode32(secret, padding: false),
      type: "string",
      category: "auth"
    )

    AlexClaw.Config.set("auth.totp.enabled", "true", type: "boolean", category: "auth")
    AlexClaw.Config.delete("auth.totp.last_used_at")

    secret
  end

  # A spent recovery code writes two rows — one for the attempt, one for the
  # code being used — and they share a second. The attempt row is the one under
  # test here, so it is found by its permission rather than by being newest.
  defp latest(decision) do
    AuditLog.recent(limit: 20, decision: decision)
    |> Enum.find(&(&1.permission == "admin.second_factor"))
  end

  describe "an accepted authenticator code" do
    test "records the factor and the route", ctx do
      :ok = CodeEntry.verify(ctx.sid, NimbleTOTP.verification_code(ctx.secret), :web)

      assert latest("accepted").reason =~ "factor: totp"
      assert latest("accepted").reason =~ "method: web"
    end

    test "records the gateway route when it came in that way", ctx do
      chat = "chat-#{System.unique_integer([:positive])}"
      TOTP.create_challenge(chat, %{type: :test})

      {:ok, _action} = TOTP.resolve_challenge(chat, NimbleTOTP.verification_code(ctx.secret))

      assert latest("accepted").reason =~ "method: gateway"
      assert latest("accepted").reason =~ "factor: totp"
    end
  end

  describe "an accepted recovery code" do
    test "is recorded as a recovery code, not as an authenticator code", ctx do
      [recovery | _rest] = RecoveryCodes.generate()

      :ok = CodeEntry.verify(ctx.sid, recovery, :web)

      assert latest("accepted").reason =~ "factor: recovery_code"
      refute latest("accepted").reason =~ "factor: totp"
    end

    test "names the session that spent it, by fingerprint", ctx do
      [recovery | _rest] = RecoveryCodes.generate()

      :ok = CodeEntry.verify(ctx.sid, recovery, :web)
      row = latest("accepted")

      assert row.caller_type == "admin"
      assert String.starts_with?(row.caller, "admin:")
      refute String.contains?(row.caller, ctx.sid)
    end
  end

  describe "a refused code" do
    # A code that matched nothing is not evidence of which kind it was meant to
    # be, and guessing would put a fact in the log that nobody established.
    test "records the route but claims no factor", ctx do
      {:error, :invalid_code} = CodeEntry.verify(ctx.sid, "000000", :web)

      assert latest("refused").reason =~ "method: web"
      assert latest("refused").reason =~ "factor: unknown"
    end

    test "still names the route for a gateway attempt", ctx do
      chat = "chat-#{System.unique_integer([:positive])}"
      TOTP.create_challenge(chat, %{type: :test})

      TOTP.resolve_challenge(chat, "000000")

      assert latest("refused").reason =~ "method: gateway"
      assert ctx.sid
    end
  end
end
