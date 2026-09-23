defmodule AlexClaw.Auth.GatePromptTest do
  @moduledoc """
  The 2FA prompt a gateway receives (reports/GATEWAY_CRASH_2026-09-23.md §3,
  §7).

  `Gate.request/2` sent the prompt to every configured chat without checking
  the lock: a locked chat received "Enter your 6-digit authenticator code"
  and could not answer it — on 2026-09-23 that answer is what crashed the
  gateway. And the prompt did not say WHICH authenticator entry: with two
  similarly named entries on a phone, three codes came from the wrong one
  and locked the chat.

  Now:
  - a locked destination gets no prompt; when no destination can be
    prompted, `request/2` returns `{:locked, minutes}` so the caller can say
    so (the admin UI shows it instead of "check Telegram");
  - the prompt names the authenticator entry: the TOTP issuer, as the app
    shows it when enrolling (`TOTP_ISSUER`, default "AlexClaw").
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.RecordingGateway
  alias AlexClaw.Auth.{Challenge, CodeAttempts, Gate, TOTP}

  setup do
    CodeAttempts.reset()
    on_exit(&CodeAttempts.reset/0)

    {:ok, %{secret: secret}} = TOTP.setup()
    :ok = TOTP.confirm_setup(NimbleTOTP.verification_code(secret))

    chat = "gate_#{System.unique_integer([:positive])}"
    insert_setting("telegram.chat_id", chat, type: "string", category: "telegram")
    insert_setting("discord.channel_id", "", type: "string", category: "discord")
    RecordingGateway.install()

    %{chat: chat}
  end

  defp prompts, do: Enum.filter(RecordingGateway.sent(), &(&1 =~ ~r/authenticator/i))

  test "an unlocked chat is prompted, and the prompt names the authenticator entry" do
    assert :challenged = Gate.request(%{type: :test}, "Unlock admin editing for 15 minutes")

    assert [prompt] = prompts()
    issuer = System.get_env("TOTP_ISSUER") || "AlexClaw"
    assert prompt =~ ~r/authenticator entry/i
    assert prompt =~ issuer
  end

  test "a locked chat gets no prompt it cannot answer", %{chat: chat} do
    Challenge.create(chat, %{type: :test})
    for wrong <- ~w(000000 000001 000002), do: Challenge.resolve(chat, wrong)
    RecordingGateway.clear()

    assert {:locked, minutes} =
             Gate.request(%{type: :test}, "Unlock admin editing for 15 minutes")

    assert minutes in 1..5
    assert prompts() == []
    refute Challenge.pending?(chat), "a challenge was raised for a chat that cannot answer it"
  end
end
