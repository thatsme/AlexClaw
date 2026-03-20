defmodule AlexClaw.Gateway.RouterTest do
  use AlexClaw.DataCase, async: false

  alias AlexClaw.Gateway.Router

  describe "resolve routing" do
    test "send_message with gateway: :telegram routes to Telegram" do
      assert :ok = Router.send_message("test", gateway: :telegram)
    end

    test "send_message without gateway routes to default" do
      assert :ok = Router.send_message("test")
    end

    test "send_html routes through correctly" do
      assert :ok = Router.send_html("<b>test</b>", gateway: :telegram)
    end
  end

  describe "active_gateways/0" do
    test "returns list of configured gateways" do
      gateways = Router.active_gateways()
      assert is_list(gateways)
    end

    test "includes Telegram when configured" do
      AlexClaw.Config.set("telegram.bot_token", "test-token", type: "string", category: "telegram")
      assert AlexClaw.Gateway.Telegram in Router.active_gateways()
    end

    test "excludes Telegram when not configured" do
      AlexClaw.Config.set("telegram.bot_token", "", type: "string", category: "telegram")
      refute AlexClaw.Gateway.Telegram in Router.active_gateways()
    end
  end

  describe "broadcast/2" do
    test "does not crash with no active gateways" do
      AlexClaw.Config.set("telegram.bot_token", "", type: "string", category: "telegram")
      assert :ok = Router.broadcast("system notification")
    end
  end
end
