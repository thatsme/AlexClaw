defmodule AlexClaw.Dispatcher.OperateNotAuthorTest do
  @moduledoc """
  A chat operates AlexClaw; it never authors it (reports/S5_ONE_DOOR.md §4,
  reports/S5_INVENTORY.md §8; 0.4.0 S5b).

  What a chat may still do: run skills and unprotected workflows, and approve
  a PROTECTED workflow run with a code (§4.1). What it may no longer do:
  - write a setting (`--tier` did, on a plain command);
  - start a recording, replay one, or automate a page (`/record`, `/replay`,
    `/automate` — admin UI only, §4.3);
  - turn the second factor on (`/confirm 2fa`), or connect/disconnect Google;
  - run a shell command or generate a skill (`/shell`, `/coder`) — a shell
    command from chat is a protected workflow run with a code;
  - approve anything but a protected run with a code (a restore, an
    elevation, a shell command did);
  - become the owner chat by being the first to write: the owner chat is set
    in the admin UI, and messages from any other chat are ignored.

  Each refused command answers where to do it instead, and changes nothing.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  import Ecto.Query

  alias AlexClaw.{Dispatcher, Message, RecordingGateway}

  @owner "owner-chat-4242"

  setup do
    RecordingGateway.install()
    insert_setting("telegram.chat_id", @owner, type: "string", category: "telegram")
    :ok
  end

  defp say(text, chat \\ @owner) do
    Dispatcher.dispatch(%Message{
      text: text,
      chat_id: chat,
      from: "Test",
      timestamp: DateTime.utc_now(),
      raw: %{},
      gateway: :test
    })

    RecordingGateway.sent()
  end

  # Every settings row and its last change, to prove a command wrote nothing.
  defp settings_snapshot do
    Repo.all(from(s in AlexClaw.Config.Setting, select: {s.key, s.updated_at}, order_by: s.key))
  end

  describe "writes that a chat can no longer make" do
    test "--tier on a command writes no setting" do
      before = settings_snapshot()
      say("/research --tier heavy what is OpenBao")
      assert settings_snapshot() == before
    end

    for command <- ["/record https://example.com", "/replay 1", "/automate https://example.com"] do
      test "#{command} is refused and points to the admin UI" do
        sent = say(unquote(command))

        assert Enum.any?(sent, &(&1 =~ ~r/admin UI/i)),
               "no pointer to the admin UI in #{inspect(sent)}"
      end
    end

    test "/confirm 2fa does not turn the second factor on" do
      say("/confirm 2fa 123456")
      refute AlexClaw.Auth.TOTP.enabled?()
    end

    for command <- ["/connect google", "/disconnect google"] do
      test "#{command} is refused and points to the admin UI" do
        sent = say(unquote(command))
        assert Enum.any?(sent, &(&1 =~ ~r/admin UI/i))
      end
    end

    for command <- ["/shell ls -la", "/coder make a skill that says hello"] do
      test "#{command} is refused" do
        before = settings_snapshot()
        sent = say(unquote(command))

        assert Enum.any?(sent, &(&1 =~ ~r/admin UI|protected workflow/i))
        assert settings_snapshot() == before
      end
    end
  end

  describe "a code typed into a chat approves a protected run, and nothing else" do
    test "the only action a chat code can approve is a protected workflow run" do
      assert AlexClaw.Dispatcher.AuthCommands.chat_approvable() == [:run_protected_workflow]
    end

    for action <- [:database_restore, :shell, :elevation] do
      test "a code in chat cannot approve #{action}" do
        msg = %Message{
          text: "123456",
          chat_id: @owner,
          from: "Test",
          timestamp: DateTime.utc_now(),
          raw: %{},
          gateway: :test
        }

        assert {:error, _} =
                 AlexClaw.Dispatcher.AuthCommands.execute_2fa_action(unquote(action), msg)
      end
    end
  end

  describe "the owner chat" do
    test "a message from another chat is ignored, and does not make it the owner" do
      sent = say("/help", "stranger-chat-9999")

      assert sent == []
      assert AlexClaw.Config.get("telegram.chat_id") == @owner
    end

    test "with no owner set, the first chat to write does not become the owner" do
      AlexClaw.Config.set("telegram.chat_id", "", type: "string", category: "telegram")

      say("/start", "first-chat-1111")

      assert AlexClaw.Config.get("telegram.chat_id") in [nil, ""]
    end
  end
end
