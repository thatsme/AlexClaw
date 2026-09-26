defmodule AlexClaw.Auth.RecoveryWhenTotpCannotTest do
  @moduledoc """
  A recovery code works whenever the authenticator cannot answer (S9 fix
  review, ruling on N2; THREAT_MODEL P4, P10).

  An authenticator key from before 0.4.0 that has not been, or cannot be,
  imported into OpenBao leaves TOTP "unavailable". Recovery codes are the way
  back in for exactly that case, so they are tried then too: before, the
  browser's code entry answered "unavailable" without asking them, and an
  instance whose old key could never be imported had no way in at all.

  An authenticator code typed meanwhile stays "unavailable", not wrong (S8
  M11): it is not counted. A recovery code OpenBao answers "no" to is wrong.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :vault

  alias AlexClaw.Auth.{CodeAttempts, RecoveryCodes}
  alias AlexClaw.Auth.SecondFactor.Totp
  alias AlexClaw.Config
  alias AlexClawTest.Legacy

  setup do
    CodeAttempts.reset()
    on_exit(&CodeAttempts.reset/0)

    for key <- ~w(auth.totp.enabled auth.totp.secret auth.totp.last_used_at
                  auth.totp.key auth.totp.pending),
        do: Config.delete(key)

    Config.set("auth.totp.enabled", "true", type: "boolean", category: "auth")
    %{codes: RecoveryCodes.generate()}
  end

  describe "with an old key not yet imported" do
    setup do
      secret = NimbleTOTP.secret()

      Legacy.insert_setting("auth.totp.secret", Base.encode32(secret, padding: false),
        encrypted: true
      )

      %{secret: secret}
    end

    test "a recovery code is accepted, once", %{codes: [code | _]} do
      assert {:ok, :recovery_code} = Totp.verify(code, :web)
      assert {:error, :invalid_code} = Totp.verify(code, :web)
    end

    test "an authenticator code is unavailable, not wrong", %{secret: secret} do
      assert {:error, :unavailable} = Totp.verify(NimbleTOTP.verification_code(secret), :web)
    end

    test "a recovery code is still refused over a gateway", %{codes: [code | _]} do
      assert {:error, _} = Totp.verify(code, :gateway)
      assert RecoveryCodes.valid?(code)
    end
  end

  describe "with an old key that can never be imported" do
    setup do
      # 0.3.x ciphertext under a key this instance does not have.
      Legacy.insert_setting(
        "auth.totp.secret",
        "enc:" <> Base.encode64(:crypto.strong_rand_bytes(48)),
        encrypted: false
      )

      :ok
    end

    test "a recovery code is accepted", %{codes: [code | _]} do
      assert {:ok, :recovery_code} = Totp.verify(code, :web)
    end

    test "a wrong recovery code is wrong", %{codes: _codes} do
      assert {:error, :invalid_code} = Totp.verify("AAAAA-BBBBB", :web)
    end
  end
end
