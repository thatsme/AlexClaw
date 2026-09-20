defmodule AlexClaw.Auth.UnifiedVerificationTest do
  @moduledoc """
  One verifier, whichever way the code arrived.

  The gateway path used to check codes itself, which meant two implementations
  of "is this code good" and two sets of counters. A limit that only one of them
  respected is not a limit: an attacker would have used the other door.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.{Challenge, ChallengeStore, CodeAttempts, CodeEntry, RecoveryCodes, TOTP}

  setup do
    CodeAttempts.reset()
    RecoveryCodes.discard()
    secret = enable_totp()

    on_exit(fn ->
      CodeAttempts.reset()
      RecoveryCodes.discard()
    end)

    {:ok, secret: secret, chat: "chat-#{System.unique_integer([:positive])}"}
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

  defp challenge(chat), do: Challenge.create(chat, %{type: :run_workflow, workflow_id: 1})

  describe "the counters are shared" do
    # The point of unifying: ten wrong codes are ten wrong codes, whether they
    # were typed into the page or sent to a bot.
    test "wrong codes split across web and gateway trip the instance lock", ctx do
      for n <- 1..5 do
        CodeEntry.verify("web-session-#{n}", "000000", :web)
      end

      for n <- 1..4 do
        chat = "#{ctx.chat}-#{n}"
        challenge(chat)
        Challenge.resolve(chat, "000000")
      end

      # Nine so far, from both sides, and nothing is locked yet.
      assert CodeAttempts.status("anyone") == :ok

      challenge(ctx.chat)
      Challenge.resolve(ctx.chat, "000000")

      assert {:locked, :instance, _until} = CodeAttempts.status("anyone"),
             "ten wrong codes across both routes did not reach the instance limit"
    end

    test "a gateway lock stops the web field too", ctx do
      for n <- 1..CodeAttempts.instance_limit() do
        chat = "#{ctx.chat}-#{n}"
        challenge(chat)
        Challenge.resolve(chat, "000000")
      end

      assert {:error, :locked_instance} =
               CodeEntry.verify("a-web-session", code(ctx.secret), :web)
    end

    # Per chat, not per gateway: one chat guessing should not lock another.
    test "three wrong codes from one chat lock that chat alone", ctx do
      other = "#{ctx.chat}-other"

      for _n <- 1..3 do
        challenge(ctx.chat)
        Challenge.resolve(ctx.chat, "000000")
      end

      assert {:locked, :session, _until} = CodeAttempts.status("chat:" <> ctx.chat)
      assert CodeAttempts.status("chat:" <> other) == :ok
    end
  end

  describe "the gateway path" do
    test "still accepts a correct code and returns the action", ctx do
      challenge(ctx.chat)

      assert {:ok, action} = Challenge.resolve(ctx.chat, code(ctx.secret))
      assert action.type == :run_workflow
    end

    test "still refuses a replayed code", ctx do
      used = code(ctx.secret)
      challenge(ctx.chat)
      {:ok, _action} = Challenge.resolve(ctx.chat, used)

      challenge(ctx.chat)

      assert {:error, _reason} = Challenge.resolve(ctx.chat, used)
    end

    test "still expires a challenge", ctx do
      challenge(ctx.chat)
      {:ok, stored} = ChallengeStore.fetch(ctx.chat)

      ChallengeStore.put(ctx.chat, %{
        stored
        | expires_at: System.monotonic_time(:second) - 1
      })

      assert {:error, :challenge_expired} = Challenge.resolve(ctx.chat, code(ctx.secret))
    end

    test "reports a lock rather than burning the pending action", ctx do
      for n <- 1..CodeAttempts.instance_limit() do
        CodeEntry.verify("web-session-#{n}", "000000", :web)
      end

      challenge(ctx.chat)

      assert {:error, :locked_instance} = Challenge.resolve(ctx.chat, "000000")
      assert Challenge.pending?(ctx.chat), "a locked-out attempt discarded the action"
    end
  end

  # Decided and documented: recovery codes are typed in the browser and nowhere
  # else. Accepting one over a gateway would write the way back in into a chat
  # transcript on someone else's server — the same reason they are never sent
  # there. The admin UI is always available, so nothing is lost by refusing.
  describe "recovery codes over a gateway" do
    test "are refused", ctx do
      [recovery | _rest] = RecoveryCodes.generate()
      challenge(ctx.chat)

      assert {:error, _reason} = Challenge.resolve(ctx.chat, recovery)

      assert RecoveryCodes.remaining() == RecoveryCodes.count(),
             "a recovery code was spent by a gateway attempt"
    end

    test "but the same code still works in the browser", ctx do
      [recovery | _rest] = RecoveryCodes.generate()
      challenge(ctx.chat)
      {:error, _reason} = Challenge.resolve(ctx.chat, recovery)

      assert :ok = CodeEntry.verify("a-web-session", recovery, :web)
      assert RecoveryCodes.remaining() == RecoveryCodes.count() - 1
    end
  end

  defp code(secret), do: NimbleTOTP.verification_code(secret)
end
