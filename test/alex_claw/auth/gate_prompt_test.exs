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
  - the prompt names the authenticator entry AS ENROLLED: the issuer is
    recorded when 2FA is confirmed, and the prompt uses the recorded one, not
    today's `TOTP_ISSUER` (the phone's entry keeps the name it was enrolled
    with). An enrolment with no record predates 0.3.47, when `TOTP_ISSUER`
    never reached the app, so its entry is named "AlexClaw".
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.{Challenge, CodeAttempts, Gate, TOTP}
  alias AlexClaw.RecordingGateway

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

  defp command(chat, text) do
    AlexClaw.Dispatcher.dispatch(%AlexClaw.Message{
      text: text,
      chat_id: chat,
      from: "Test",
      timestamp: DateTime.utc_now(),
      raw: %{},
      gateway: :test
    })
  end

  test "an unlocked chat is prompted, and the prompt names the authenticator entry" do
    assert :challenged = Gate.request(%{type: :test}, "Unlock admin editing for 15 minutes")

    assert [prompt] = prompts()
    assert prompt =~ ~r/authenticator entry/i
    assert prompt =~ "AlexClaw"
  end

  describe "the entry named is the one enrolled, not today's TOTP_ISSUER" do
    setup do
      previous = System.get_env("TOTP_ISSUER")

      on_exit(fn ->
        if previous,
          do: System.put_env("TOTP_ISSUER", previous),
          else: System.delete_env("TOTP_ISSUER")
      end)
    end

    test "changing TOTP_ISSUER after enrolment does not change the name in the prompt" do
      # Enrolled (in the outer setup) with the default issuer.
      System.put_env("TOTP_ISSUER", "AlexClaw-Air")

      assert :challenged = Gate.request(%{type: :test}, "Unlock admin editing for 15 minutes")
      assert [prompt] = prompts()
      assert prompt =~ "AlexClaw"
      refute prompt =~ "AlexClaw-Air", "the prompt names today's issuer, not the enrolled one"
    end

    test "an enrolment made with a custom issuer is named by it" do
      TOTP.disable()
      System.put_env("TOTP_ISSUER", "Terminal-Ops")
      {:ok, %{secret: secret}} = TOTP.setup()
      :ok = TOTP.confirm_setup(NimbleTOTP.verification_code(secret))
      System.put_env("TOTP_ISSUER", "Something-Else")

      assert :challenged = Gate.request(%{type: :test}, "Unlock admin editing for 15 minutes")
      assert [prompt] = prompts()
      assert prompt =~ "Terminal-Ops"
      refute prompt =~ "Something-Else"
    end

    test "an enrolment with no recorded issuer is named AlexClaw" do
      # What an instance enrolled before this release looks like.
      AlexClaw.Repo.delete_all(
        from(s in AlexClaw.Config.Setting, where: s.key == "auth.totp.issuer")
      )

      AlexClaw.Config.reload()
      System.put_env("TOTP_ISSUER", "AlexClaw-Air")

      assert :challenged = Gate.request(%{type: :test}, "Unlock admin editing for 15 minutes")
      assert [prompt] = prompts()
      assert prompt =~ "AlexClaw"
      refute prompt =~ "AlexClaw-Air"
    end
  end

  # The second way a gateway is prompted: a Telegram command that needs a code
  # (AuthCommands.require_2fa/3, e.g. /shell). Same rules as Gate.request/2 —
  # one prompt builder, one lock check.
  describe "commands that need a code" do
    test "prompt with the enrolled entry's name", %{chat: chat} do
      command(chat, "/shell uptime")
      assert [prompt] = prompts()
      assert prompt =~ ~r/authenticator entry/i
      assert prompt =~ "AlexClaw"
    end

    test "a locked chat gets the lock, not a prompt", %{chat: chat} do
      Challenge.create(chat, %{type: :test})
      for wrong <- ~w(000000 000001 000002), do: Challenge.resolve(chat, wrong)
      RecordingGateway.clear()

      command(chat, "/shell uptime")

      assert prompts() == []
      assert List.last(RecordingGateway.sent()) =~ ~r/locked/i
      refute Challenge.pending?(chat)
    end
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
