defmodule AlexClaw.Skills.TelegramNotifyAdversarialTest do
  use AlexClaw.DataCase, async: false

  alias AlexClaw.Skills.TelegramNotify

  describe "input formatting" do
    test "handles list input" do
      result = TelegramNotify.run(%{input: [1, 2, 3], config: %{}})
      assert {:ok, %{delivered: true}, _branch} = result
    end

    test "handles tuple input" do
      result = TelegramNotify.run(%{input: {:ok, "tuple"}, config: %{}})
      assert {:ok, %{delivered: true}, _branch} = result
    end

    test "handles integer input" do
      result = TelegramNotify.run(%{input: 42, config: %{}})
      assert {:ok, %{delivered: true}, _branch} = result
    end

    test "handles deeply nested map" do
      nested = %{"a" => %{"b" => %{"c" => %{"d" => "deep"}}}}
      result = TelegramNotify.run(%{input: nested, config: %{}})
      assert {:ok, %{delivered: true}, _branch} = result
    end

    test "handles map without 'output' key" do
      result = TelegramNotify.run(%{input: %{"other" => "key"}, config: %{}})
      assert {:ok, %{delivered: true}, _branch} = result
    end

    test "handles empty string" do
      result = TelegramNotify.run(%{input: "", config: %{}})
      assert {:ok, %{delivered: true}, _branch} = result
    end

    test "handles string with Telegram markdown special chars" do
      result = TelegramNotify.run(%{
        input: "*bold* _italic_ `code` [link](url) ~strike~",
        config: %{}
      })
      assert {:ok, %{delivered: true}, _branch} = result
    end
  end

  describe "truncation" do
    test "message over 4000 chars gets truncated" do
      huge = String.duplicate("x", 5000)
      result = TelegramNotify.run(%{input: huge, config: %{}})
      assert {:ok, %{delivered: true}, _branch} = result
    end

    test "message exactly at 4000 chars is not truncated" do
      exact = String.duplicate("x", 4000)
      result = TelegramNotify.run(%{input: exact, config: %{}})
      assert {:ok, %{delivered: true}, _branch} = result
    end
  end

  describe "custom bot validation" do
    test "empty bot_token falls through to gateway" do
      result = TelegramNotify.run(%{input: "test", config: %{"bot_token" => ""}})
      assert {:ok, %{delivered: true}, _branch} = result
    end

    test "bot_token with nil chat_id returns error" do
      result = TelegramNotify.run(%{input: "test", config: %{"bot_token" => "tok", "chat_id" => nil}})
      assert {:error, :no_chat_id} = result
    end

    test "bot_token with empty chat_id returns error" do
      result = TelegramNotify.run(%{input: "test", config: %{"bot_token" => "tok", "chat_id" => ""}})
      assert {:error, :no_chat_id} = result
    end
  end

  describe "missing args" do
    test "empty args defaults gracefully" do
      result = TelegramNotify.run(%{})
      assert {:ok, %{delivered: true}, _branch} = result
    end

    test "nil config defaults to empty map" do
      result = TelegramNotify.run(%{input: "test", config: nil})
      assert {:ok, %{delivered: true}, _branch} = result
    end
  end
end
