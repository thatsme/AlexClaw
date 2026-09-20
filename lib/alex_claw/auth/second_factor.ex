defmodule AlexClaw.Auth.SecondFactor do
  @moduledoc """
  What counts as a second factor, and how to ask it.

  There is one implementation — `AlexClaw.Auth.SecondFactor.Totp`, which checks
  the authenticator and the recovery codes behind it — and the seam exists
  because everything around it should not have to know that. Rate limiting,
  auditing, the code fields, the per-action gates and the elevation window all
  belong to "a code was presented and it held", not to TOTP specifically.

  A WebAuthn or hardware-key implementation would answer the same three
  questions. The point of the behaviour is that adding one is a new module and
  a config line, not a search through the places that currently say TOTP.

  Selected with:

      config :alex_claw, :second_factor, AlexClaw.Auth.SecondFactor.Totp

  """

  @typedoc "Where the operator presented the factor."
  @type method :: :web | :gateway

  @typedoc "What was presented and accepted."
  @type factor :: :totp | :recovery_code

  @doc """
  Check a presented secret.

  `method` is passed because an implementation may accept different things by
  route — the TOTP implementation takes recovery codes in the browser and not
  over a gateway, since a chat transcript is a durable copy of them.

  Returns which factor was accepted, so the audit row can say. Counting the
  attempt and refusing a locked-out caller are not this module's business:
  `AlexClaw.Auth.CodeEntry` owns those, for every implementation.
  """
  @callback verify(secret :: String.t(), method :: method()) ::
              {:ok, factor()} | {:error, :invalid_code}

  @doc "Whether a second factor exists to be asked for on this instance."
  @callback configured?() :: boolean()

  @doc "A short name for this factor, for logs and for the UI."
  @callback name() :: atom()

  @doc "The configured implementation."
  @spec impl() :: module()
  def impl do
    Application.get_env(:alex_claw, :second_factor, AlexClaw.Auth.SecondFactor.Totp)
  end
end
