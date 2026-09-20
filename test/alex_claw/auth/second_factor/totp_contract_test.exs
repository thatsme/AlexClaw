defmodule AlexClaw.Auth.SecondFactor.TotpContractTest do
  @moduledoc """
  The shipped second factor, held to the contract every implementation must keep.

  The same file will run against a WebAuthn implementation the day there is
  one; that is the point of writing the promises down separately from the
  module that currently keeps them.
  """
  alias AlexClaw.Auth.RecoveryCodes
  alias AlexClaw.Auth.SecondFactor.Totp

  use AlexClaw.SecondFactorContract,
    impl: Totp,
    setup: &__MODULE__.configure/0

  @doc false
  def configure do
    secret = NimbleTOTP.secret()

    AlexClaw.Config.set("auth.totp.secret", Base.encode32(secret, padding: false),
      type: "string",
      category: "auth"
    )

    AlexClaw.Config.set("auth.totp.enabled", "true", type: "boolean", category: "auth")
    AlexClaw.Config.delete("auth.totp.last_used_at")

    RecoveryCodes.discard()
    [recovery | _rest] = RecoveryCodes.generate()

    %{valid: NimbleTOTP.verification_code(secret), web_only: recovery}
  end
end
