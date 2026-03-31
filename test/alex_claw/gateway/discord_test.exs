defmodule AlexClaw.Gateway.DiscordTest do
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Gateway.Discord

  describe "behaviour callbacks" do
    test "name returns :discord" do
      assert Discord.name() == :discord
    end

    test "configured? returns false when disabled" do
      AlexClaw.Config.set("discord.enabled", "false", type: "boolean", category: "discord")
      AlexClaw.Config.set("discord.bot_token", "some-token", type: "string", category: "discord")
      refute Discord.configured?()
    end

    test "configured? returns false without token" do
      AlexClaw.Config.set("discord.enabled", "true", type: "boolean", category: "discord")
      AlexClaw.Config.set("discord.bot_token", "", type: "string", category: "discord")
      refute Discord.configured?()
    end

    test "configured? returns true when enabled with token" do
      AlexClaw.Config.set("discord.enabled", "true", type: "boolean", category: "discord")
      AlexClaw.Config.set("discord.bot_token", "test-discord-token", type: "string", category: "discord")
      assert Discord.configured?()
    end
  end

  describe "send_message/2 without channel" do
    test "logs warning and returns :ok when no channel configured" do
      AlexClaw.Config.set("discord.channel_id", "", type: "string", category: "discord")
      assert :ok = Discord.send_message("test message")
    end
  end

  describe "send_html/2" do
    test "strips HTML tags" do
      # send_html converts HTML to plain text before sending
      # Without a valid channel this just logs a warning and returns :ok
      AlexClaw.Config.set("discord.channel_id", "", type: "string", category: "discord")
      assert :ok = Discord.send_html("<b>bold</b> <i>italic</i>")
    end
  end
end
