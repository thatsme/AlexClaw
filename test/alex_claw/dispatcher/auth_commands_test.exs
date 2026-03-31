defmodule AlexClaw.Dispatcher.AuthCommandsTest do
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.{Dispatcher, Message}

  defp msg(text) do
    %Message{text: text, chat_id: "123", from: "Test", timestamp: DateTime.utc_now(), raw: %{}, gateway: :test}
  end

  describe "2FA commands routing" do
    test "/setup 2fa dispatches without crash" do
      result = Dispatcher.dispatch(msg("/setup 2fa"))
      assert result != :ignored
    end

    test "/confirm 2fa dispatches without crash" do
      result = Dispatcher.dispatch(msg("/confirm 2fa 123456"))
      assert result != :ignored
    end

    test "/disable 2fa dispatches without crash" do
      result = Dispatcher.dispatch(msg("/disable 2fa"))
      assert result != :ignored
    end
  end

  describe "OAuth commands routing" do
    test "/connect shows available services" do
      result = Dispatcher.dispatch(msg("/connect"))
      assert result != :ignored
    end

    test "/connect google dispatches without crash" do
      result = Dispatcher.dispatch(msg("/connect google"))
      assert result != :ignored
    end

    test "/disconnect google dispatches without crash" do
      result = Dispatcher.dispatch(msg("/disconnect google"))
      assert result != :ignored
    end
  end

  describe "require_2fa/3" do
    test "returns :proceed when 2FA is not enabled" do
      assert :proceed = Dispatcher.AuthCommands.require_2fa(msg("/test"), %{type: :test}, "Test action")
    end
  end
end
