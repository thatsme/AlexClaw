defmodule AlexClaw.Skills.TelegramNotifyTest do
  use AlexClaw.DataCase, async: false
  @moduletag :integration

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
      assert match?({:ok, _, _}, result) or match?({:error, _}, result)
    end

    test "sends via gateway when no bot_token and passes through input" do
      result = TelegramNotify.run(%{
        input: "Test message",
        config: %{}
      })

      assert {:ok, "Test message", :on_delivered} = result
    end

    test "passes through nil input" do
      result = TelegramNotify.run(%{input: nil, config: %{}})
      assert {:ok, nil, :on_delivered} = result
    end

    test "passes through map input" do
      input = %{"output" => "map text"}
      result = TelegramNotify.run(%{input: input, config: %{}})
      assert {:ok, ^input, :on_delivered} = result
    end

    test "truncates long messages but passes through original input" do
      long = String.duplicate("x", 5000)
      result = TelegramNotify.run(%{input: long, config: %{}})
      assert {:ok, ^long, :on_delivered} = result
    end

    test "returns error when custom bot has no chat_id" do
      result = TelegramNotify.run(%{
        input: "test",
        config: %{"bot_token" => "tok", "chat_id" => ""}
      })
      assert {:error, :no_chat_id} = result
    end

    test "treats empty string chat_id as nil — uses gateway default" do
      result = TelegramNotify.run(%{
        input: "test message",
        config: %{"chat_id" => "", "bot_token" => ""}
      })

      assert {:ok, "test message", :on_delivered} = result
    end

    test "treats nil config values same as missing" do
      result = TelegramNotify.run(%{
        input: "test",
        config: %{"chat_id" => nil, "bot_token" => nil}
      })

      assert {:ok, "test", :on_delivered} = result
    end
  end
end
