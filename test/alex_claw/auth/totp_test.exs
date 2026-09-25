defmodule AlexClaw.Auth.TOTPTest do
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.{Challenge, CodeAttempts, TOTP}
  alias AlexClaw.Config
  alias AlexClaw.Config.Crypto

  describe "setup/0" do
    test "generates a secret and QR code" do
      assert {:ok, %{secret: secret, uri: uri, qr_png: qr_png}} = TOTP.setup()
      assert is_binary(secret)
      assert byte_size(secret) > 0
      assert uri =~ "otpauth://totp/"
      assert uri =~ "AlexClaw"
      assert is_binary(qr_png)
      assert byte_size(qr_png) > 0
    end

    test "stores pending secret in config" do
      {:ok, _} = TOTP.setup()
      pending = AlexClaw.Config.get("auth.totp.pending_secret")
      assert is_binary(pending)
      assert pending != ""
    end

    test "pending secret is encrypted at rest in database" do
      {:ok, _} = TOTP.setup()
      record = Repo.get_by(Config.Setting, key: "auth.totp.pending_secret")
      assert record.sensitive == true
      assert Crypto.encrypted?(record.value)
    end
  end

  describe "confirm_setup/1" do
    test "returns error when no pending setup" do
      assert {:error, :no_pending_setup} = TOTP.confirm_setup("123456")
    end

    test "returns error for invalid code" do
      {:ok, _} = TOTP.setup()
      assert {:error, :invalid_code} = TOTP.confirm_setup("000000")
    end

    test "activates 2FA with valid code" do
      {:ok, %{secret: secret}} = TOTP.setup()
      code = NimbleTOTP.verification_code(secret)

      assert :ok = TOTP.confirm_setup(code)
      assert TOTP.enabled?()
    end

    test "active secret is encrypted at rest in database" do
      {:ok, %{secret: secret}} = TOTP.setup()
      code = NimbleTOTP.verification_code(secret)
      :ok = TOTP.confirm_setup(code)

      record = Repo.get_by(Config.Setting, key: "auth.totp.secret")
      assert record.sensitive == true
      assert Crypto.encrypted?(record.value)
    end
  end

  describe "enabled?/0" do
    test "returns false by default" do
      refute TOTP.enabled?()
    end

    test "returns true after setup and confirmation" do
      {:ok, %{secret: secret}} = TOTP.setup()
      code = NimbleTOTP.verification_code(secret)
      :ok = TOTP.confirm_setup(code)

      assert TOTP.enabled?()
    end
  end

  describe "verify/1" do
    test "returns false when no secret configured" do
      refute TOTP.verify("123456")
    end

    test "returns true for valid code" do
      {:ok, %{secret: secret}} = TOTP.setup()
      code = NimbleTOTP.verification_code(secret)
      :ok = TOTP.confirm_setup(code)

      new_code = NimbleTOTP.verification_code(secret)
      assert TOTP.verify(new_code)
    end

    test "returns false for invalid code" do
      {:ok, %{secret: secret}} = TOTP.setup()
      code = NimbleTOTP.verification_code(secret)
      :ok = TOTP.confirm_setup(code)

      refute TOTP.verify("000000")
    end
  end

  # disable/1 verifies the current code itself (0.4.0): no caller can turn
  # 2FA off by forgetting to check. The code it receives goes through the same
  # verification as any other, replay protection included — so these tests
  # move the last-used marker back before using a fresh code.
  describe "disable/1" do
    defp enabled_secret do
      {:ok, %{secret: secret}} = TOTP.setup()
      :ok = TOTP.confirm_setup(NimbleTOTP.verification_code(secret))

      AlexClaw.Config.set("auth.totp.last_used_at", to_string(System.os_time(:second) - 120),
        type: "string",
        category: "auth"
      )

      secret
    end

    test "a current code disables 2FA" do
      secret = enabled_secret()
      assert TOTP.enabled?()

      :ok = TOTP.disable(NimbleTOTP.verification_code(secret))
      refute TOTP.enabled?()
    end

    test "a wrong code does not" do
      enabled_secret()

      assert {:error, :invalid_code} = TOTP.disable("000000")
      assert TOTP.enabled?()
    end

    # The lost-phone path. Recovery codes exist for exactly this: without it,
    # a lost authenticator would lock the admin out for good.
    test "a recovery code disables 2FA, and every code is wiped" do
      enabled_secret()
      codes = AlexClaw.Auth.RecoveryCodes.generate()

      :ok = TOTP.disable(hd(codes))
      refute TOTP.enabled?()

      # With 2FA off, leftover recovery codes mean nothing: all are wiped, the
      # one used included.
      refute Enum.any?(codes, &AlexClaw.Auth.RecoveryCodes.valid?/1)
    end
  end

  describe "challenge system" do
    test "create and resolve challenge" do
      {:ok, %{secret: secret}} = TOTP.setup()
      code = NimbleTOTP.verification_code(secret)
      :ok = TOTP.confirm_setup(code)

      action = %{type: :run_workflow, workflow_id: 1}
      _challenge_id = Challenge.create("chat_123", action)

      assert Challenge.pending?("chat_123")

      new_code = NimbleTOTP.verification_code(secret)
      assert {:ok, ^action} = Challenge.resolve("chat_123", new_code)

      refute Challenge.pending?("chat_123")
    end

    test "returns error for invalid code on challenge" do
      {:ok, %{secret: secret}} = TOTP.setup()
      code = NimbleTOTP.verification_code(secret)
      :ok = TOTP.confirm_setup(code)

      Challenge.create("chat_456", %{type: :test})
      assert {:error, :invalid_code} = Challenge.resolve("chat_456", "000000")
      assert Challenge.pending?("chat_456")
    end

    test "returns error when no challenge exists" do
      assert {:error, :no_challenge} = Challenge.resolve("no_chat", "123456")
    end

    test "pending_challenge? returns false for unknown chat" do
      refute Challenge.pending?("unknown_chat")
    end
  end

  # A code is valid for its whole 30-second period, so one seen in transit could
  # be used again inside that window.
  describe "replay protection" do
    test "a valid code is accepted once and refused on reuse" do
      {:ok, %{secret: secret}} = TOTP.setup()
      :ok = TOTP.confirm_setup(NimbleTOTP.verification_code(secret))

      code = NimbleTOTP.verification_code(secret)

      assert TOTP.verify(code)
      refute TOTP.verify(code)
    end

    test "a code from a period after the last acceptance is allowed" do
      {:ok, %{secret: secret}} = TOTP.setup()
      :ok = TOTP.confirm_setup(NimbleTOTP.verification_code(secret))

      AlexClaw.Config.set("auth.totp.last_used_at", to_string(System.os_time(:second) - 120),
        type: "string",
        category: "auth"
      )

      assert TOTP.verify(NimbleTOTP.verification_code(secret))
    end

    test "acceptance is recorded as a row, outside the config cache" do
      {:ok, %{secret: secret}} = TOTP.setup()
      :ok = TOTP.confirm_setup(NimbleTOTP.verification_code(secret))

      assert TOTP.verify(NimbleTOTP.verification_code(secret))

      assert Repo.get_by(Config.Setting, key: "auth.totp.last_used_at")

      # Outside the cache, and now refused rather than answered with nil — a
      # caller that could not tell the guard from an absent value wrote an empty
      # default over the secret on every boot.
      assert :ets.lookup(:alexclaw_config, "auth.totp.last_used_at") == []

      assert_raise ArgumentError, ~r/not served through Config.get/, fn ->
        Config.get("auth.totp.last_used_at")
      end
    end

    test "a skill cannot read the marker" do
      assert AlexClaw.Config.sensitive?("auth.totp.last_used_at")
    end

    test "disabling 2FA clears the marker" do
      {:ok, %{secret: secret}} = TOTP.setup()
      :ok = TOTP.confirm_setup(NimbleTOTP.verification_code(secret))
      assert TOTP.verify(NimbleTOTP.verification_code(secret))

      # The code just accepted cannot be replayed; move the marker back so a
      # fresh code is valid for disable/1, which verifies it.
      AlexClaw.Config.set("auth.totp.last_used_at", to_string(System.os_time(:second) - 120),
        type: "string",
        category: "auth"
      )

      :ok = TOTP.disable(NimbleTOTP.verification_code(secret))

      refute AlexClaw.Repo.get_by(AlexClaw.Config.Setting, key: "auth.totp.last_used_at")
    end

    test "a rejected code is not recorded" do
      {:ok, %{secret: secret}} = TOTP.setup()
      :ok = TOTP.confirm_setup(NimbleTOTP.verification_code(secret))

      refute TOTP.verify("000000")
      refute AlexClaw.Repo.get_by(AlexClaw.Config.Setting, key: "auth.totp.last_used_at")

      assert TOTP.verify(NimbleTOTP.verification_code(secret))
    end
  end

  # The challenge lives for two minutes and accepts any six digits in that time.
  # Without a limit those two minutes are a guessing window.
  #
  # The per-challenge count is not the only one any more: codes are verified by
  # CodeEntry whichever way they arrive, so the session and instance limits
  # count these attempts too. The counters are reset per test, because what is
  # under test here is the challenge's own limit.
  describe "challenge attempt limit" do
    setup do
      CodeAttempts.reset()
      on_exit(&CodeAttempts.reset/0)
      :ok
    end

    defp enable_2fa do
      {:ok, %{secret: secret}} = TOTP.setup()
      :ok = TOTP.confirm_setup(NimbleTOTP.verification_code(secret))
      secret
    end

    defp chat, do: "limit_#{System.unique_integer([:positive])}"

    test "the third invalid code cancels the challenge" do
      enable_2fa()
      chat = chat()
      Challenge.create(chat, %{type: :test})

      assert {:error, :invalid_code} = Challenge.resolve(chat, "000000")
      assert {:error, :invalid_code} = Challenge.resolve(chat, "000001")
      assert {:error, :too_many_attempts} = Challenge.resolve(chat, "000002")

      refute Challenge.pending?(chat)
    end

    test "a correct code after the limit is refused — the challenge is gone" do
      secret = enable_2fa()
      chat = chat()
      Challenge.create(chat, %{type: :test})

      for wrong <- ~w(000000 000001 000002), do: Challenge.resolve(chat, wrong)

      assert {:error, :no_challenge} =
               Challenge.resolve(chat, NimbleTOTP.verification_code(secret))
    end

    test "a correct code before the limit still resolves" do
      secret = enable_2fa()
      chat = chat()
      action = %{type: :test}
      Challenge.create(chat, action)

      assert {:error, :invalid_code} = Challenge.resolve(chat, "000000")
      assert {:error, :invalid_code} = Challenge.resolve(chat, "000001")

      assert {:ok, ^action} = Challenge.resolve(chat, NimbleTOTP.verification_code(secret))
    end

    test "a code accepted for a challenge cannot be replayed on the next one" do
      secret = enable_2fa()
      first = chat()
      Challenge.create(first, %{type: :test})
      code = NimbleTOTP.verification_code(secret)

      assert {:ok, _action} = Challenge.resolve(first, code)

      second = chat()
      Challenge.create(second, %{type: :test})
      assert {:error, :invalid_code} = Challenge.resolve(second, code)
    end

    test "a new challenge does not inherit the old one's count" do
      enable_2fa()
      chat = chat()
      Challenge.create(chat, %{type: :test})

      for wrong <- ~w(000000 000001 000002), do: Challenge.resolve(chat, wrong)

      # The chat-level counter is what the next challenge would meet; clearing
      # it isolates the question this test asks, which is about the challenge.
      CodeAttempts.reset()
      Challenge.create(chat, %{type: :test})

      assert {:error, :invalid_code} = Challenge.resolve(chat, "000003")
      assert Challenge.pending?(chat)
    end

    # Three attempts per challenge and unlimited challenges is unlimited
    # attempts. Since codes are verified by CodeEntry, the chat is locked after
    # three wrong ones and raising a fresh challenge buys nothing.
    test "re-raising a challenge does not buy three more guesses" do
      enable_2fa()
      chat = chat()
      Challenge.create(chat, %{type: :test})

      for wrong <- ~w(000000 000001 000002), do: Challenge.resolve(chat, wrong)

      Challenge.create(chat, %{type: :test})

      assert {:error, :locked_session} = Challenge.resolve(chat, "000003")
    end
  end
end
