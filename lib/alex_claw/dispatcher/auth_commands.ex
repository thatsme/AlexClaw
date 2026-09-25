defmodule AlexClaw.Dispatcher.AuthCommands do
  @moduledoc """
  Chat commands about the second factor and connections, and the one thing a
  code typed into a chat approves: a protected workflow run.

  A chat operates AlexClaw; it never authors it (0.4.0 S5b). Setting up,
  confirming or turning off the second factor, and connecting or
  disconnecting Google, are done in the admin UI; each command here answers
  where. A code answered in a chat approves the protected run it was asked
  for (`chat_approvable/0`), performed as `:run_protected_workflow` through
  `AlexClaw.ControlPlane.perform/3`, which checks the code against that
  chat's challenge.
  """
  alias AlexClaw.Auth.{Challenge, Gate, TOTP}
  alias AlexClaw.ControlPlane
  alias AlexClaw.ControlPlane.Context
  alias AlexClaw.Gateway
  alias AlexClaw.Message

  @spec dispatch(Message.t()) :: :ok | term()

  # A chat is not a place for the factor that guards everything else: its
  # secret never travels over one, and it is neither confirmed nor turned off
  # from one.
  def dispatch(%Message{text: "/setup 2fa" <> _} = msg),
    do:
      answer(
        "Two-factor authentication is set up in the admin UI (Services page), not over a chat.",
        msg
      )

  def dispatch(%Message{text: "/confirm 2fa" <> _} = msg),
    do:
      answer(
        "Two-factor authentication is confirmed in the admin UI (Services page), not over a chat.",
        msg
      )

  def dispatch(%Message{text: "/disable 2fa" <> _} = msg) do
    answer(
      "Two-factor authentication is turned off in the admin UI (Services page), " <>
        "with an authenticator code or a recovery code — not over a chat.",
      msg
    )
  end

  def dispatch(%Message{text: "/connect" <> _} = msg),
    do: answer("Google is connected in the admin UI (Services page), not over a chat.", msg)

  def dispatch(%Message{text: "/disconnect" <> _} = msg),
    do: answer("Google is disconnected in the admin UI (Services page), not over a chat.", msg)

  defp answer(text, msg),
    do: Gateway.send_message(text, chat_id: msg.chat_id, gateway: msg.gateway)

  # --- 2FA Helpers ---

  @doc """
  Wraps a sensitive action with a 2FA challenge.

  Returns `:challenged` once the code has been requested, `:no_2fa` when TOTP
  is not configured, and `{:locked, minutes}` when the chat is locked after too
  many wrong codes — it is told so instead of being prompted. Callers must treat
  both as a refusal: the action is not performed.
  """
  @spec require_2fa(Message.t(), map(), String.t()) ::
          :challenged | :no_2fa | {:locked, pos_integer()}
  def require_2fa(msg, action, description) do
    challenge_2fa(msg, action, description, TOTP.enabled?())
  end

  # Fail closed: an action that asked for a second factor is refused when there is
  # no second factor to ask for, rather than running unprotected.
  defp challenge_2fa(_msg, _action, _description, false), do: :no_2fa

  # The same lock check and prompt as Gate.request/2: a chat that cannot answer
  # is not asked.
  defp challenge_2fa(msg, action, description, true) do
    msg.chat_id
    |> Challenge.lock()
    |> ask(msg, action, description)
  end

  defp ask(:ok, msg, action, description) do
    Challenge.create(msg.chat_id, action)
    Gateway.send_message(Gate.prompt(description), chat_id: msg.chat_id, gateway: msg.gateway)
    :challenged
  end

  defp ask({:locked, minutes} = locked, msg, _action, _description) do
    Gateway.send_message(Gate.lock_notice(minutes), chat_id: msg.chat_id, gateway: msg.gateway)
    locked
  end

  @doc "The catalogue actions a code typed into a chat can approve."
  @spec chat_approvable() :: [atom()]
  def chat_approvable, do: [:run_protected_workflow]

  @doc """
  Perform the action a chat's challenge is waiting for, with the code in
  `msg` — only a protected workflow run. Anything else is refused.
  """
  @spec execute_2fa_action(term(), Message.t()) :: {:ok, term()} | {:error, term()}
  def execute_2fa_action(%{type: :run_workflow, workflow_id: id}, %Message{} = msg) do
    ControlPlane.perform(
      :run_protected_workflow,
      %{workflow_id: id},
      Context.gateway(msg.chat_id, String.trim(msg.text || ""))
    )
  end

  def execute_2fa_action(_action, _msg), do: {:error, :not_chat_approvable}
end
