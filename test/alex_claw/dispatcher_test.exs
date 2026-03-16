defmodule AlexClaw.DispatcherTest do
  use AlexClaw.DataCase, async: false

  alias AlexClaw.{Dispatcher, Message}

  describe "dispatch/1 pattern matching" do
    test "matches /ping" do
      msg = %Message{text: "/ping", chat_id: "123", from: "Test", timestamp: DateTime.utc_now(), raw: %{}}
      assert Dispatcher.dispatch(msg)
    end

    test "matches /help" do
      msg = %Message{text: "/help", chat_id: "123", from: "Test", timestamp: DateTime.utc_now(), raw: %{}}
      assert Dispatcher.dispatch(msg)
    end

    test "matches /status" do
      msg = %Message{text: "/status", chat_id: "123", from: "Test", timestamp: DateTime.utc_now(), raw: %{}}
      assert Dispatcher.dispatch(msg)
    end

    test "matches /skills" do
      msg = %Message{text: "/skills", chat_id: "123", from: "Test", timestamp: DateTime.utc_now(), raw: %{}}
      assert Dispatcher.dispatch(msg)
    end

    test "matches /rss" do
      msg = %Message{text: "/rss", chat_id: "123", from: "Test", timestamp: DateTime.utc_now(), raw: %{}}
      assert Dispatcher.dispatch(msg)
    end

    test "matches /rss force" do
      msg = %Message{text: "/rss force", chat_id: "123", from: "Test", timestamp: DateTime.utc_now(), raw: %{}}
      assert Dispatcher.dispatch(msg)
    end

    test "ignores nil message" do
      assert :ignored = Dispatcher.dispatch(%Message{text: nil, chat_id: nil, from: nil, timestamp: nil, raw: %{}})
    end
  end
end
