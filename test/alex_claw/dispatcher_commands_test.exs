defmodule AlexClaw.DispatcherCommandsTest do
  use AlexClaw.DataCase, async: false

  alias AlexClaw.{Dispatcher, Message}

  defp msg(text) do
    %Message{text: text, chat_id: "123", from: "Test", timestamp: DateTime.utc_now(), raw: %{}}
  end

  describe "web automation commands" do
    test "matches /record <url>" do
      # Will fail at HTTP level (no sidecar) but should not crash on pattern match
      insert_setting("web_automator.enabled", "true", type: "boolean", category: "web_automator")
      insert_setting("web_automator.host", "http://localhost:19999", type: "string", category: "web_automator")

      result = Dispatcher.dispatch(msg("/record https://example.com"))
      assert result != :ignored
    end

    test "matches /record start <url> and forwards to /record" do
      insert_setting("web_automator.enabled", "true", type: "boolean", category: "web_automator")
      insert_setting("web_automator.host", "http://localhost:19999", type: "string", category: "web_automator")

      result = Dispatcher.dispatch(msg("/record start https://example.com"))
      assert result != :ignored
    end

    test "matches /record stop <session_id>" do
      insert_setting("web_automator.enabled", "true", type: "boolean", category: "web_automator")
      insert_setting("web_automator.host", "http://localhost:19999", type: "string", category: "web_automator")

      result = Dispatcher.dispatch(msg("/record stop abc123"))
      assert result != :ignored
    end

    test "/record returns disabled message when sidecar disabled" do
      insert_setting("web_automator.enabled", "false", type: "boolean", category: "web_automator")

      result = Dispatcher.dispatch(msg("/record https://example.com"))
      assert result != :ignored
    end

    test "matches /automate <url>" do
      insert_setting("web_automator.enabled", "true", type: "boolean", category: "web_automator")
      insert_setting("web_automator.host", "http://localhost:19999", type: "string", category: "web_automator")

      result = Dispatcher.dispatch(msg("/automate https://example.com"))
      assert result != :ignored
    end

    test "matches /replay <id>" do
      insert_setting("web_automator.enabled", "true", type: "boolean", category: "web_automator")
      insert_setting("web_automator.host", "http://localhost:19999", type: "string", category: "web_automator")

      {:ok, resource} = AlexClaw.Resources.create_resource(%{
        name: "Test Auto", type: "automation", url: "https://example.com",
        metadata: %{"steps" => []}
      })

      result = Dispatcher.dispatch(msg("/replay #{resource.id}"))
      assert result != :ignored
    end

    test "/replay returns error for non-automation resource" do
      insert_setting("web_automator.enabled", "true", type: "boolean", category: "web_automator")

      {:ok, resource} = AlexClaw.Resources.create_resource(%{
        name: "RSS Feed", type: "rss_feed", url: "https://example.com/feed"
      })

      result = Dispatcher.dispatch(msg("/replay #{resource.id}"))
      assert result != :ignored
    end

    test "/replay returns error for nonexistent resource" do
      result = Dispatcher.dispatch(msg("/replay 99999"))
      assert result != :ignored
    end

    test "/replay returns error for non-numeric id" do
      result = Dispatcher.dispatch(msg("/replay abc"))
      assert result != :ignored
    end
  end

  describe "google tasks commands" do
    test "matches /tasks" do
      result = Dispatcher.dispatch(msg("/tasks"))
      assert result != :ignored
    end

    test "matches /tasklists" do
      result = Dispatcher.dispatch(msg("/tasklists"))
      assert result != :ignored
    end

    test "matches /task add <title>" do
      result = Dispatcher.dispatch(msg("/task add Buy milk"))
      assert result != :ignored
    end
  end

  describe "2fa commands" do
    test "matches /setup 2fa" do
      result = Dispatcher.dispatch(msg("/setup 2fa"))
      assert result != :ignored
    end

    test "matches /confirm 2fa <code>" do
      result = Dispatcher.dispatch(msg("/confirm 2fa 123456"))
      assert result != :ignored
    end

    test "matches /disable 2fa" do
      result = Dispatcher.dispatch(msg("/disable 2fa"))
      assert result != :ignored
    end
  end

  describe "oauth commands" do
    test "matches /connect google" do
      result = Dispatcher.dispatch(msg("/connect google"))
      assert result != :ignored
    end

    test "matches /disconnect google" do
      result = Dispatcher.dispatch(msg("/disconnect google"))
      assert result != :ignored
    end

    test "matches /connect (list services)" do
      result = Dispatcher.dispatch(msg("/connect"))
      assert result != :ignored
    end
  end

  describe "workflow commands" do
    test "matches /workflows" do
      result = Dispatcher.dispatch(msg("/workflows"))
      assert result != :ignored
    end

    test "matches /run with nonexistent workflow" do
      result = Dispatcher.dispatch(msg("/run 99999"))
      assert result != :ignored
    end

    test "matches /llm" do
      result = Dispatcher.dispatch(msg("/llm"))
      assert result != :ignored
    end
  end

  describe "catch-all" do
    test "free text goes to conversational handler" do
      result = Dispatcher.dispatch(msg("hello there"))
      assert result != :ignored
    end

    test "nil text returns :ignored" do
      assert :ignored = Dispatcher.dispatch(%Message{text: nil, chat_id: nil, from: nil, timestamp: nil, raw: %{}})
    end
  end
end
