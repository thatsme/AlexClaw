defmodule AlexClaw.Gateway.TelegramTest do
  use AlexClaw.DataCase, async: false

  alias AlexClaw.Gateway.Telegram

  setup do
    AlexClaw.Config.set("telegram.poll_interval", "infinity", type: "string", category: "telegram")
    :ok
  end

  describe "send_message/2 golden path" do
    test "sends cast to GenServer without crashing" do
      assert :ok = Telegram.send_message("test message")
    end

    test "accepts chat_id override" do
      assert :ok = Telegram.send_message("test", chat_id: "12345")
    end

    test "handles empty message" do
      assert :ok = Telegram.send_message("")
    end

    test "handles long message" do
      long = String.duplicate("a", 5000)
      assert :ok = Telegram.send_message(long)
    end

    test "handles unicode message" do
      assert :ok = Telegram.send_message("Ciao! 🦇 Привет 日本語")
    end
  end

  describe "send_message/2 adversarial" do
    test "handles nil chat_id gracefully" do
      assert :ok = Telegram.send_message("test", chat_id: nil)
    end

    test "handles message with markdown special chars" do
      assert :ok = Telegram.send_message("*bold* _italic_ `code` [link](url)")
    end

    test "handles message with newlines" do
      assert :ok = Telegram.send_message("line1\nline2\nline3")
    end
  end

  describe "behaviour callbacks" do
    test "name returns :telegram" do
      assert Telegram.name() == :telegram
    end

    test "configured? returns false without token" do
      AlexClaw.Config.set("telegram.bot_token", "", type: "string", category: "telegram")
      refute Telegram.configured?()
    end

    test "configured? returns true with token and enabled" do
      AlexClaw.Config.set("telegram.enabled", "true", type: "boolean", category: "telegram")
      AlexClaw.Config.set("telegram.bot_token", "test-token-123", type: "string", category: "telegram")
      assert Telegram.configured?()
    end
  end

  describe "GenServer state" do
    test "Telegram gateway is alive and registered" do
      assert Process.whereis(AlexClaw.Gateway.Telegram) != nil
    end

    test "responds to sys:get_state" do
      state = :sys.get_state(Telegram)
      assert is_map(state)
      assert Map.has_key?(state, :offset)
    end
  end

  describe "facade backward compatibility" do
    test "AlexClaw.Gateway.send_message delegates correctly" do
      assert :ok = AlexClaw.Gateway.send_message("test via facade")
    end

    test "AlexClaw.Gateway.send_html delegates correctly" do
      assert :ok = AlexClaw.Gateway.send_html("<b>test</b>")
    end
  end
end
