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
  - the other results keep their replies.

  Since 0.4.0 (S5b): only the owner chat is answered, so each test's chat is
  the owner; and a chat code approves a PROTECTED WORKFLOW RUN and nothing
  else, so the pending action is one. A pending action of any other kind is
  answered "admin UI" without the code being checked.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  import Ecto.Query

  alias AlexClaw.Auth.{Challenge, CodeAttempts, TOTP}
  alias AlexClaw.{Dispatcher, Message, RecordingGateway, Workflows}

  setup do
    # A correct code starts a real run, in its own process.
    Ecto.Adapters.SQL.Sandbox.mode(AlexClaw.Repo, {:shared, self()})
    CodeAttempts.reset()
    on_exit(&CodeAttempts.reset/0)
    RecordingGateway.install()

    {:ok, %{secret: secret}} = TOTP.setup()
    :ok = TOTP.confirm_setup(NimbleTOTP.verification_code(secret))
    # The confirming code cannot be replayed; let a fresh one through.
    AlexClaw.Config.delete("auth.totp.last_used_at")

    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "sf-protected-#{System.unique_integer([:positive])}",
        enabled: true,
        metadata: %{"requires_2fa" => true}
      })

    %{secret: secret, wf: wf}
  end

  # A chat that is the owner: only the owner chat is answered.
  defp owner_chat do
    chat = "sf_#{System.unique_integer([:positive])}"
    AlexClaw.Config.set("telegram.chat_id", chat, type: "string", category: "telegram")
    chat
  end

  defp run_approval(wf), do: %{type: :run_workflow, workflow_id: wf.id}

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
  defp lock(chat, wf) do
    wrong_codes(chat, 3, wf)
    Challenge.create(chat, run_approval(wf))
  end

  defp wrong_codes(chat, count, wf) do
    Challenge.create(chat, run_approval(wf))
    for wrong <- Enum.take(~w(000000 000001 000002), count), do: Challenge.resolve(chat, wrong)
  end

  defp runs_of(wf) do
    Repo.aggregate(
      from(r in AlexClaw.Workflows.WorkflowRun, where: r.workflow_id == ^wf.id),
      :count
    )
  end

  describe "a code sent to a locked chat" do
    test "gets an answer instead of crashing the gateway", %{wf: wf} do
      chat = owner_chat()
      lock(chat, wf)

      answer = reply(chat, "123456")

      assert is_binary(answer), "no reply was sent"
      assert answer =~ ~r/locked/i
      assert answer =~ ~r/minute/i, "the reply should say the lock is temporary"
    end

    test "a correct code is still refused while locked, and nothing runs", %{
      secret: secret,
      wf: wf
    } do
      chat = owner_chat()
      lock(chat, wf)

      answer = reply(chat, NimbleTOTP.verification_code(secret))

      assert answer =~ ~r/locked/i
      refute answer =~ ~r/verified|executing/i
      assert runs_of(wf) == 0
    end
  end

  describe "a code sent while the whole instance is locked" do
    # Ten wrong codes across any routes lock every chat for fifteen minutes:
    # three chats with three wrong codes each, and one more.
    test "gets an answer instead of crashing the gateway", %{wf: wf} do
      for count <- [3, 3, 3, 1],
          do: wrong_codes("other_#{System.unique_integer([:positive])}", count, wf)

      chat = owner_chat()
      Challenge.create(chat, run_approval(wf))

      assert {:error, :locked_instance} = Challenge.resolve(chat, "000003"),
             "premise: ten wrong codes lock the instance"

      answer = reply(chat, "123456")

      assert is_binary(answer), "no reply was sent"
      assert answer =~ ~r/locked/i
    end
  end

  describe "the other results keep their replies" do
    test "a correct code starts the protected run", %{secret: secret, wf: wf} do
      chat = owner_chat()
      Challenge.create(chat, run_approval(wf))

      reply(chat, NimbleTOTP.verification_code(secret))

      assert Enum.any?(RecordingGateway.sent(), &(&1 =~ ~r/verified/i))

      assert Enum.any?(1..100, fn _ -> runs_of(wf) > 0 or (Process.sleep(20) && false) end),
             "the approved run never started"

      # Let the run finish inside the test's sandbox.
      assert Enum.any?(1..100, fn _ ->
               Repo.exists?(
                 from(r in AlexClaw.Workflows.WorkflowRun,
                   where: r.workflow_id == ^wf.id and r.status != "running"
                 )
               ) or (Process.sleep(20) && false)
             end)
    end

    test "a wrong code says try again", %{wf: wf} do
      chat = owner_chat()
      Challenge.create(chat, run_approval(wf))
      assert reply(chat, "000000") =~ ~r/invalid code/i
    end

    test "the third wrong code cancels the challenge", %{wf: wf} do
      chat = owner_chat()
      Challenge.create(chat, run_approval(wf))
      reply(chat, "000000")
      reply(chat, "000001")
      assert reply(chat, "000002") =~ ~r/too many/i
    end
  end

  describe "a pending action a chat cannot approve" do
    test "is answered 'admin UI', and the code is not even checked", %{secret: secret} do
      chat = owner_chat()
      Challenge.create(chat, %{type: :database_restore})
      before = CodeAttempts.status(chat)

      answer = reply(chat, NimbleTOTP.verification_code(secret))

      assert answer =~ ~r/admin UI/i
      refute answer =~ ~r/verified|executing/i
      assert CodeAttempts.status(chat) == before, "the code was checked"
    end
  end
end
