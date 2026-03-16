defmodule AlexClaw.DispatcherAdversarialTest do
  use AlexClaw.DataCase, async: false

  alias AlexClaw.{Dispatcher, Message}

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(AlexClaw.Repo, {:shared, self()})
    :ok
  end

  describe "dispatch/1 edge cases" do
    test "nil message is ignored" do
      assert :ignored = Dispatcher.dispatch(nil)
    end

    test "empty struct (no text) is ignored" do
      assert :ignored = Dispatcher.dispatch(%Message{})
    end

    test "nil text is ignored" do
      assert :ignored = Dispatcher.dispatch(%Message{text: nil})
    end

    test "command with extra whitespace works" do
      result = Dispatcher.dispatch(%Message{text: "/ping   extra stuff", chat_id: 1})
      assert result != :ignored
    end

    test "command injection — text starting with / but not a valid command goes to conversation" do
      msg = %Message{text: "/notacommand something", chat_id: 1, from: "test"}
      result = Dispatcher.dispatch(msg)
      refute result == :ignored
    end

    test "very long text doesn't crash" do
      long_text = String.duplicate("a", 50_000)
      msg = %Message{text: long_text, chat_id: 1, from: "test"}
      result = Dispatcher.dispatch(msg)
      refute result == :ignored
    end

    test "unicode text dispatches to conversational" do
      msg = %Message{text: "こんにちは 🤖", chat_id: 1, from: "test"}
      result = Dispatcher.dispatch(msg)
      refute result == :ignored
    end

    test "/web with no url returns gracefully without crashing" do
      msg = %Message{text: "/web ", chat_id: 1}
      result = Dispatcher.dispatch(msg)
      refute is_nil(result)
    end

    test "/research with empty query" do
      msg = %Message{text: "/research ", chat_id: 1}
      result = Dispatcher.dispatch(msg)
      assert result != :ignored
    end

    test "/search with empty query" do
      msg = %Message{text: "/search ", chat_id: 1}
      result = Dispatcher.dispatch(msg)
      assert result != :ignored
    end
  end
end
