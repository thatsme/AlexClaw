defmodule AlexClaw.Auth.TOTPTest do
  use AlexClaw.DataCase, async: false

  alias AlexClaw.Auth.TOTP

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
      assert AlexClaw.Config.Crypto.encrypted?(record.value)
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
      assert AlexClaw.Config.Crypto.encrypted?(record.value)
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
end
