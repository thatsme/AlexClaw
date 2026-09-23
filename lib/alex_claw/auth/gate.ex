defmodule AlexClaw.Auth.Gate do
  @moduledoc """
  Second-factor gate for actions triggered from the admin UI.

  `request/2` raises a challenge for every configured gateway chat that can
  answer it, broadcasts the prompt, and returns `:challenged`. A chat locked
  after too many wrong codes cannot answer, so it gets no challenge; when no
  chat can answer, nothing is sent and `request/2` returns `{:locked, minutes}`,
  the time until the first one can. It returns `:no_2fa` when there is no second
  factor to ask for — either TOTP is disabled or no gateway is configured to
  receive the prompt. Callers must treat both as a refusal.

  The verified action is carried out by `AlexClaw.Dispatcher.AuthCommands.execute_2fa_action/2`
  once the user replies with a valid code, so the action map passed here must be
  one that function understands.
  """

  alias AlexClaw.Auth.{Challenge, Principal, SecondFactor}
  alias AlexClaw.Config
  alias AlexClaw.Gateway.Router

  @type result :: :challenged | :no_2fa | {:locked, pos_integer()}

  @doc """
  Request 2FA for `action`, describing it to the user as `description`.

  Fails closed: an action that asked for a second factor is never performed
  without one.
  """
  @spec request(map(), String.t()) :: result()
  def request(action, description) do
    challenge(SecondFactor.impl().configured?() && notify_chat_ids(), action, description)
  end

  @doc """
  Every destination a prompt for this action was sent to.

  Public because a code answered in the admin UI has to withdraw the same
  challenge from the gateways it was also sent to, or the action could be
  performed twice.
  """
  @spec notify_targets() :: [String.t()]
  def notify_targets, do: notify_chat_ids()

  defp notify_chat_ids do
    Enum.filter(
      [Config.get("telegram.chat_id"), Config.get("discord.channel_id")],
      &(&1 && &1 != "")
    )
  end

  # The action carries who asked for it. Whoever answers the code approves it,
  # and today that is the same principal — the fields are separate because the
  # case worth recording is the one where they are not.
  defp with_principal(action) do
    Map.merge(action, %{requested_by: Principal.requested_by()})
  end

  defp challenge(chat_ids, _action, _description) when chat_ids in [false, []], do: :no_2fa

  defp challenge(chat_ids, action, description) do
    chat_ids
    |> Enum.map(&{&1, Challenge.lock(&1)})
    |> Enum.split_with(fn {_id, lock} -> lock == :ok end)
    |> prompt(action, description)
  end

  # The broadcast reaches every gateway; only the chats that can answer hold a
  # challenge.
  defp prompt({[], locked}, _action, _description) do
    {:locked, locked |> Enum.map(fn {_id, {:locked, minutes}} -> minutes end) |> Enum.min()}
  end

  defp prompt({open, _locked}, action, description) do
    for {id, :ok} <- open, do: Challenge.create(id, with_principal(action))

    Router.broadcast(prompt(description))
    :challenged
  end

  @doc """
  The prompt a gateway chat receives for `description`, naming the
  authenticator entry to read the code from. Every 2FA prompt sent to a
  gateway is built here.
  """
  @spec prompt(String.t()) :: String.t()
  def prompt(description) do
    "This action requires 2FA verification.\n#{description}\n\n" <>
      "Enter the 6-digit code from your authenticator entry \"#{SecondFactor.impl().entry_name()}\":"
  end

  @doc "What a chat locked for `minutes` more is told instead of a prompt."
  @spec lock_notice(pos_integer()) :: String.t()
  def lock_notice(minutes) do
    "Code entry is locked after too many wrong codes — no code was requested. " <>
      "Try again in #{minutes} min."
  end
end
