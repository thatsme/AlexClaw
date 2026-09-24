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

      AlexClaw.Config.set("discord.bot_token", "test-discord-token",
        type: "string",
        category: "discord"
      )

      assert Discord.configured?()
    end
  end

  describe "send_message/2 without channel" do
    # It used to log a warning and return :ok — a send to nowhere reported as
    # a success. Since 0.3.53 it is an error (discord_delivery_test.exs).
    test "returns {:error, :no_channel_id} when no channel is configured" do
      AlexClaw.Config.set("discord.channel_id", "", type: "string", category: "discord")
      assert {:error, :no_channel_id} = Discord.send_message("test message")
    end
  end

  describe "send_html/2" do
    # What this test is about is the HTML stripping: the text Discord receives
    # has no tags. Observed on the API behaviour, with a channel configured.
    test "strips HTML tags before sending" do
      Application.put_env(:alex_claw, :discord_api, AlexClaw.Gateway.Discord.APIMock)
      on_exit(fn -> Application.delete_env(:alex_claw, :discord_api) end)
      Mox.set_mox_global()

      AlexClaw.Config.set("discord.channel_id", "123456789", type: "string", category: "discord")
      test_pid = self()

      Mox.stub(AlexClaw.Gateway.Discord.APIMock, :create_message, fn _channel, content ->
        send(test_pid, {:content, content})
        {:ok, %{id: 1}}
      end)

      Discord.send_html("<b>bold</b> <i>italic</i>")

      assert_receive {:content, content}, 2_000
      assert content =~ "bold"
      assert content =~ "italic"
      refute content =~ "<b>"
      refute content =~ "<i>"
    end
  end
end
