defmodule AlexClaw.Auth.TOTPTest do
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.TOTP
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
      record = AlexClaw.Repo.get_by(AlexClaw.Config.Setting, key: "auth.totp.pending_secret")
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

      record = AlexClaw.Repo.get_by(AlexClaw.Config.Setting, key: "auth.totp.secret")
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

  describe "disable/0" do
    test "disables 2FA" do
      {:ok, %{secret: secret}} = TOTP.setup()
      code = NimbleTOTP.verification_code(secret)
      :ok = TOTP.confirm_setup(code)
      assert TOTP.enabled?()

      :ok = TOTP.disable()
      refute TOTP.enabled?()
    end
  end

  describe "challenge system" do
    test "create and resolve challenge" do
      {:ok, %{secret: secret}} = TOTP.setup()
      code = NimbleTOTP.verification_code(secret)
      :ok = TOTP.confirm_setup(code)

      action = %{type: :run_workflow, workflow_id: 1}
      _challenge_id = TOTP.create_challenge("chat_123", action)

      assert TOTP.pending_challenge?("chat_123")

      new_code = NimbleTOTP.verification_code(secret)
      assert {:ok, ^action} = TOTP.resolve_challenge("chat_123", new_code)

      refute TOTP.pending_challenge?("chat_123")
    end

    test "returns error for invalid code on challenge" do
      {:ok, %{secret: secret}} = TOTP.setup()
      code = NimbleTOTP.verification_code(secret)
      :ok = TOTP.confirm_setup(code)

      TOTP.create_challenge("chat_456", %{type: :test})
      assert {:error, :invalid_code} = TOTP.resolve_challenge("chat_456", "000000")
      assert TOTP.pending_challenge?("chat_456")
    end

    test "returns error when no challenge exists" do
      assert {:error, :no_challenge} = TOTP.resolve_challenge("no_chat", "123456")
    end

    test "pending_challenge? returns false for unknown chat" do
      refute TOTP.pending_challenge?("unknown_chat")
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

      assert AlexClaw.Repo.get_by(AlexClaw.Config.Setting, key: "auth.totp.last_used_at")
      assert AlexClaw.Config.get("auth.totp.last_used_at") == nil
    end

    test "a skill cannot read the marker" do
      assert AlexClaw.Config.sensitive?("auth.totp.last_used_at")
    end

    test "disabling 2FA clears the marker" do
      {:ok, %{secret: secret}} = TOTP.setup()
      :ok = TOTP.confirm_setup(NimbleTOTP.verification_code(secret))
      assert TOTP.verify(NimbleTOTP.verification_code(secret))

      :ok = TOTP.disable()

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
  describe "challenge attempt limit" do
    defp enable_2fa do
      {:ok, %{secret: secret}} = TOTP.setup()
      :ok = TOTP.confirm_setup(NimbleTOTP.verification_code(secret))
      secret
    end

    defp chat, do: "limit_#{System.unique_integer([:positive])}"

    test "the third invalid code cancels the challenge" do
      enable_2fa()
      chat = chat()
      TOTP.create_challenge(chat, %{type: :test})

      assert {:error, :invalid_code} = TOTP.resolve_challenge(chat, "000000")
      assert {:error, :invalid_code} = TOTP.resolve_challenge(chat, "000001")
      assert {:error, :too_many_attempts} = TOTP.resolve_challenge(chat, "000002")

      refute TOTP.pending_challenge?(chat)
    end

    test "a correct code after the limit is refused — the challenge is gone" do
      secret = enable_2fa()
      chat = chat()
      TOTP.create_challenge(chat, %{type: :test})

      for wrong <- ~w(000000 000001 000002), do: TOTP.resolve_challenge(chat, wrong)

      assert {:error, :no_challenge} =
               TOTP.resolve_challenge(chat, NimbleTOTP.verification_code(secret))
    end

    test "a correct code before the limit still resolves" do
      secret = enable_2fa()
      chat = chat()
      action = %{type: :test}
      TOTP.create_challenge(chat, action)

      assert {:error, :invalid_code} = TOTP.resolve_challenge(chat, "000000")
      assert {:error, :invalid_code} = TOTP.resolve_challenge(chat, "000001")

      assert {:ok, ^action} = TOTP.resolve_challenge(chat, NimbleTOTP.verification_code(secret))
    end

    test "a code accepted for a challenge cannot be replayed on the next one" do
      secret = enable_2fa()
      first = chat()
      TOTP.create_challenge(first, %{type: :test})
      code = NimbleTOTP.verification_code(secret)

      assert {:ok, _action} = TOTP.resolve_challenge(first, code)

      second = chat()
      TOTP.create_challenge(second, %{type: :test})
      assert {:error, :invalid_code} = TOTP.resolve_challenge(second, code)
    end

    test "the count is per challenge, not per chat" do
      enable_2fa()
      chat = chat()
      TOTP.create_challenge(chat, %{type: :test})

      for wrong <- ~w(000000 000001 000002), do: TOTP.resolve_challenge(chat, wrong)

      TOTP.create_challenge(chat, %{type: :test})
      assert {:error, :invalid_code} = TOTP.resolve_challenge(chat, "000003")
      assert TOTP.pending_challenge?(chat)
    end
  end
end
