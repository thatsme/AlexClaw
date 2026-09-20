defmodule AlexClaw.Auth.Gate do
  @moduledoc """
  Second-factor gate for actions triggered from the admin UI.

  `request/2` broadcasts a TOTP challenge to every configured gateway and
  returns `:challenged`. It returns `:no_2fa` when there is no second factor to
  ask for — either TOTP is disabled or no gateway is configured to receive the
  prompt — and callers must treat that as a refusal.

  The verified action is carried out by `AlexClaw.Dispatcher.AuthCommands.execute_2fa_action/2`
  once the user replies with a valid code, so the action map passed here must be
  one that function understands.
  """

  alias AlexClaw.Auth.TOTP
  alias AlexClaw.Gateway.Credentials
  alias AlexClaw.Gateway.Router

  @type result :: :challenged | :no_2fa

  @doc """
  Request 2FA for `action`, describing it to the user as `description`.

  Fails closed: an action that asked for a second factor is never performed
  without one.
  """
  @spec request(map(), String.t()) :: result()
  def request(action, description) do
    challenge(TOTP.enabled?() && notify_chat_ids(), action, description)
  end

  # The destinations come from Credentials, not straight from the settings: a
  # blank setting falls back to the environment, which is the only way a fresh
  # instance can be asked for a code at all.
  defp notify_chat_ids, do: Credentials.notify_targets()

  defp challenge(chat_ids, _action, _description) when chat_ids in [false, []], do: :no_2fa

  defp challenge(chat_ids, action, description) do
    for id <- chat_ids, do: TOTP.create_challenge(id, action)

    Router.broadcast(
      "This action requires 2FA verification.\n#{description}\n\nEnter your 6-digit authenticator code:"
    )

    :challenged
  end
end
