defmodule AlexClaw.GatewayTest do
  use AlexClaw.DataCase, async: false

  alias AlexClaw.Gateway

  setup do
    AlexClaw.Config.set("telegram.poll_interval", "infinity", type: "string", category: "telegram")
    :ok
  end

  describe "send_message/2 golden path" do
    test "sends cast to GenServer without crashing" do
      assert :ok = Gateway.send_message("test message")
    end

    test "accepts chat_id override" do
      assert :ok = Gateway.send_message("test", chat_id: "12345")
    end

    test "handles empty message" do
      assert :ok = Gateway.send_message("")
    end

    test "handles long message" do
      long = String.duplicate("a", 5000)
      assert :ok = Gateway.send_message(long)
    end

    test "handles unicode message" do
      assert :ok = Gateway.send_message("Ciao! 🦇 Привет 日本語")
    end
  end

  describe "send_message/2 adversarial" do
    test "handles nil chat_id gracefully" do
      assert :ok = Gateway.send_message("test", chat_id: nil)
    end

    test "handles message with markdown special chars" do
      assert :ok = Gateway.send_message("*bold* _italic_ `code` [link](url)")
    end

    test "handles message with newlines" do
      assert :ok = Gateway.send_message("line1\nline2\nline3")
    end
  end

  describe "GenServer state" do
    test "Gateway is alive and registered" do
      assert Process.whereis(AlexClaw.Gateway) != nil
    end

    test "Gateway responds to sys:get_state" do
      state = :sys.get_state(Gateway)
      assert is_map(state)
      assert Map.has_key?(state, :offset)
    end
  end
end
