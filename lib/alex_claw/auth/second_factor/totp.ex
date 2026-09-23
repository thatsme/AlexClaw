defmodule AlexClaw.Auth.SecondFactor.Totp do
  @moduledoc """
  The second factor this instance ships with: an authenticator app, with
  recovery codes behind it.

  Both are the same factor from the outside — something the operator has that
  the password does not give an attacker — so both are answered here rather
  than by callers that would otherwise have to know about the difference.

  Recovery codes are accepted in the browser and refused over a gateway. They
  are never sent to a gateway, because a chat transcript is a durable copy of
  the way back in on someone else's server; typing one into a chat would put it
  there just as surely. The admin UI always accepts them, so the refusal costs
  an operator nothing.
  """
  @behaviour AlexClaw.Auth.SecondFactor

  alias AlexClaw.Auth.{RecoveryCodes, TOTP}

  @impl true
  def verify(secret, method) do
    accepted(TOTP.verify(normalize(secret)), secret, method)
  end

  # The flag is not the factor. TOTP.configured?/0 requires a secret that can
  # actually answer a code; enabled?/0 alone once reported a configured second
  # factor on an instance that had none, and there was no way out of it.
  @impl true
  def configured?, do: TOTP.configured?()

  @impl true
  def name, do: :totp

  @impl true
  def entry_name, do: TOTP.enrolled_issuer()

  # The flag is the claim; the secret is the ability to make good on it.
  @impl true
  def misconfigured?, do: TOTP.enabled?() and TOTP.secret() == nil

  defp accepted(true, _secret, _method), do: {:ok, :totp}

  defp accepted(false, secret, :web), do: spent(RecoveryCodes.redeem(secret))

  defp accepted(false, _secret, :gateway), do: {:error, :invalid_code}

  defp spent({:ok, _remaining}), do: {:ok, :recovery_code}
  defp spent({:error, :invalid_code}), do: {:error, :invalid_code}

  # Operators paste codes with the space their authenticator shows. Recovery
  # codes carry their own normalisation, since a hyphen is punctuation there.
  defp normalize(secret), do: secret |> to_string() |> String.replace(~r/\s/, "")
end
