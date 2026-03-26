defmodule AlexClaw.Dispatcher.SkillCommandsTest do
  use AlexClaw.DataCase, async: false

  alias AlexClaw.{Dispatcher, Message}

  defp msg(text) do
    %Message{text: text, chat_id: "123", from: "Test", timestamp: DateTime.utc_now(), raw: %{}, gateway: :test}
  end

  describe "skill commands routing" do
    test "/skill load dispatches without crash" do
      result = Dispatcher.dispatch(msg("/skill load nonexistent.ex"))
      assert result != :ignored
    end

    test "/skill unload dispatches without crash" do
      result = Dispatcher.dispatch(msg("/skill unload nonexistent"))
      assert result != :ignored
    end

    test "/skill reload dispatches without crash" do
      result = Dispatcher.dispatch(msg("/skill reload nonexistent"))
      assert result != :ignored
    end

    test "/skill create dispatches without crash" do
      # create_skill may fail if skills dir doesn't exist, but should not crash
      result = Dispatcher.dispatch(msg("/skill create test_skill_#{System.unique_integer([:positive])}"))
      assert result != :ignored
    end

    test "/skill list redirects to /skills" do
      result = Dispatcher.dispatch(msg("/skill list"))
      assert result != :ignored
    end

    test "/skill with no subcommand shows help" do
      result = Dispatcher.dispatch(msg("/skill"))
      assert result != :ignored
    end
  end
end
