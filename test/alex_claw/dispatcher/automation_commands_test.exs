defmodule AlexClaw.Dispatcher.AutomationCommandsTest do
  use AlexClaw.DataCase, async: false

  alias AlexClaw.{Dispatcher, Message}

  defp msg(text) do
    %Message{text: text, chat_id: "123", from: "Test", timestamp: DateTime.utc_now(), raw: %{}}
  end

  describe "automation commands routing" do
    test "/record dispatches without crash" do
      insert_setting("web_automator.enabled", "true", type: "boolean", category: "web_automator")
      insert_setting("web_automator.host", "http://localhost:19999", type: "string", category: "web_automator")

      result = Dispatcher.dispatch(msg("/record https://example.com"))
      assert result != :ignored
    end

    test "/record stop dispatches without crash" do
      insert_setting("web_automator.enabled", "true", type: "boolean", category: "web_automator")
      insert_setting("web_automator.host", "http://localhost:19999", type: "string", category: "web_automator")

      result = Dispatcher.dispatch(msg("/record stop abc123"))
      assert result != :ignored
    end

    test "/replay dispatches without crash" do
      result = Dispatcher.dispatch(msg("/replay 999"))
      assert result != :ignored
    end

    test "/automate dispatches without crash" do
      insert_setting("web_automator.enabled", "true", type: "boolean", category: "web_automator")
      insert_setting("web_automator.host", "http://localhost:19999", type: "string", category: "web_automator")

      result = Dispatcher.dispatch(msg("/automate https://example.com"))
      assert result != :ignored
    end
  end
end
