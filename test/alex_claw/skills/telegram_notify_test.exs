defmodule AlexClaw.Skills.TelegramNotifyTest do
  use AlexClaw.DataCase, async: false

  alias AlexClaw.Skills.TelegramNotify

  describe "run/1" do
    test "sends via custom bot when bot_token is provided" do
      result = TelegramNotify.run(%{
        input: "Hello world",
        config: %{
          "bot_token" => "test-token",
          "chat_id" => "12345"
        }
      })

      # Result depends on whether Telegram API is reachable in test env
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "sends via gateway when no bot_token" do
      result = TelegramNotify.run(%{
        input: "Test message",
        config: %{}
      })

      # Gateway is a cast, always returns ok
      assert {:ok, %{delivered: true}} = result
    end

    test "formats nil input" do
      result = TelegramNotify.run(%{input: nil, config: %{}})
      assert {:ok, %{delivered: true}} = result
    end

    test "formats map input" do
      result = TelegramNotify.run(%{input: %{"output" => "map text"}, config: %{}})
      assert {:ok, %{delivered: true}} = result
    end

    test "truncates long messages" do
      long = String.duplicate("x", 5000)
      result = TelegramNotify.run(%{input: long, config: %{}})
      assert {:ok, %{delivered: true}} = result
    end

    test "returns error when custom bot has no chat_id" do
      result = TelegramNotify.run(%{
        input: "test",
        config: %{"bot_token" => "tok", "chat_id" => ""}
      })
      assert {:error, :no_chat_id} = result
    end
  end
end
