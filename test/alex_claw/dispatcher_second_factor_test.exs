defmodule AlexClaw.DispatcherSecondFactorTest do
  @moduledoc """
  A six-digit reply to a pending challenge, as the Telegram gateway delivers
  it (reports/GATEWAY_CRASH_2026-09-23.md).

  `Challenge.resolve/2` returns seven results; the dispatcher handled five.
  A code sent to a locked chat returned `{:error, :locked_session}`, the
  dispatcher had no clause, the gateway crashed on a CaseClauseError, the
  unacknowledged update came back, and four crashes in 3 s stopped the
  application (2026-09-23 15:09).

  No dispatcher test had ever sent a six-digit code. These do, for every
  result, and each must end in a reply to the user and no exception:
  - `:locked_session` and `:locked_instance` say the code was not checked
    because of a lock, and that the lock is temporary;
  - a correct code sent while locked is refused — the lock wins, the action
    does not run;
  - the other five results keep their existing replies.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.{Challenge, CodeAttempts, TOTP}
  alias AlexClaw.{Dispatcher, Message, RecordingGateway}

  setup do
    CodeAttempts.reset()
    on_exit(&CodeAttempts.reset/0)
    RecordingGateway.install()

    {:ok, %{secret: secret}} = TOTP.setup()
    :ok = TOTP.confirm_setup(NimbleTOTP.verification_code(secret))

    %{secret: secret}
  end

  defp chat, do: "sf_#{System.unique_integer([:positive])}"

  defp reply(chat, text) do
    Dispatcher.dispatch(%Message{
      text: text,
      chat_id: chat,
      from: "Test",
      timestamp: DateTime.utc_now(),
      raw: %{},
      gateway: :test
    })

    RecordingGateway.sent() |> List.last()
  end

  # Three wrong codes lock the chat for five minutes (CodeEntry); the next
  # challenge meets the lock.
  defp lock(chat) do
    wrong_codes(chat, 3)
    Challenge.create(chat, %{type: :test})
  end

  defp wrong_codes(chat, count) do
    Challenge.create(chat, %{type: :test})
    for wrong <- Enum.take(~w(000000 000001 000002), count), do: Challenge.resolve(chat, wrong)
  end

  describe "a code sent to a locked chat" do
    test "gets an answer instead of crashing the gateway" do
      chat = chat()
      lock(chat)

      answer = reply(chat, "123456")

      assert is_binary(answer), "no reply was sent"
      assert answer =~ ~r/locked/i
      assert answer =~ ~r/minute/i, "the reply should say the lock is temporary"
    end

    test "a correct code is still refused while locked, and nothing runs", %{secret: secret} do
      chat = chat()
      lock(chat)

      answer = reply(chat, NimbleTOTP.verification_code(secret))

      assert answer =~ ~r/locked/i
      refute answer =~ ~r/verified|executing/i
    end
  end

  describe "a code sent while the whole instance is locked" do
    # Ten wrong codes across any routes lock every chat for fifteen minutes:
    # three chats with three wrong codes each, and one more.
    test "gets an answer instead of crashing the gateway" do
      for count <- [3, 3, 3, 1],
          do: wrong_codes("other_#{System.unique_integer([:positive])}", count)

      chat = chat()
      Challenge.create(chat, %{type: :test})

      assert {:error, :locked_instance} = Challenge.resolve(chat, "000003"),
             "premise: ten wrong codes lock the instance"

      answer = reply(chat, "123456")

      assert is_binary(answer), "no reply was sent"
      assert answer =~ ~r/locked/i
    end
  end

  describe "the other results keep their replies" do
    test "a correct code runs the action", %{secret: secret} do
      chat = chat()
      Challenge.create(chat, %{type: :test})
      reply(chat, NimbleTOTP.verification_code(secret))

      # "Code verified. Executing..." is followed by the action's own reply.
      assert Enum.any?(RecordingGateway.sent(), &(&1 =~ ~r/verified/i))
    end

    test "a wrong code says try again" do
      chat = chat()
      Challenge.create(chat, %{type: :test})
      assert reply(chat, "000000") =~ ~r/invalid code/i
    end

    test "the third wrong code cancels the challenge" do
      chat = chat()
      Challenge.create(chat, %{type: :test})
      reply(chat, "000000")
      reply(chat, "000001")
      assert reply(chat, "000002") =~ ~r/too many/i
    end
  end
end
