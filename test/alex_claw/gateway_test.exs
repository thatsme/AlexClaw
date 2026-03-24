defmodule AlexClaw.GatewayTest do
  use AlexClaw.DataCase, async: false

  alias AlexClaw.Gateway

  describe "send_message/2" do
    test "delegates without crashing" do
      assert :ok = Gateway.send_message("test message")
    end

    test "accepts keyword opts" do
      assert :ok = Gateway.send_message("test", chat_id: "123", gateway: :telegram)
    end
  end

  describe "send_html/2" do
    test "delegates without crashing" do
      assert :ok = Gateway.send_html("<b>test</b>")
    end

    test "accepts keyword opts" do
      assert :ok = Gateway.send_html("<b>test</b>", chat_id: "123", gateway: :telegram)
    end
  end
end
