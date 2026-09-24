defmodule AlexClaw.Gateway.DiscordDeliveryTest do
  @moduledoc """
  Discord sends report what Discord answered (reports/SECOND_ROUND_SEAMS.md §2;
  0.3.53).

  The gateway turned a Nostrum error into `:ok` (discord.ex:55–57), returned
  `:ok` with no channel configured (:37–40), and `discord_notify` discarded
  every result with `Enum.each`, so it always said `:on_delivered`. There was
  no stand-in for Nostrum, so no test could make a send fail.

  Now the Nostrum calls sit behind `AlexClaw.Gateway.Discord.API`
  (`create_message(channel_id, content) :: {:ok, message} | {:error, reason}`),
  Nostrum by default, chosen by `:discord_api`. The gateway returns the
  result; `discord_notify` is delivered only when every chunk was accepted.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  import Mox

  alias AlexClaw.Gateway.Discord
  alias AlexClaw.Skills.DiscordNotify

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    Application.put_env(:alex_claw, :discord_api, AlexClaw.Gateway.Discord.APIMock)
    on_exit(fn -> Application.delete_env(:alex_claw, :discord_api) end)
    insert_setting("discord.channel_id", "123456789", type: "string", category: "discord")
    # discord_notify checks Discord is configured (enabled + token) before sending.
    insert_setting("discord.enabled", "true", type: "boolean", category: "discord")
    insert_setting("discord.bot_token", "discord-test-token", type: "string", category: "discord")
    :ok
  end

  describe "Discord.send_message" do
    test "returns :ok when Discord accepts it" do
      expect(AlexClaw.Gateway.Discord.APIMock, :create_message, fn 123_456_789, "hello" ->
        {:ok, %{id: 1}}
      end)

      assert :ok = Discord.send_message("hello", [])
    end

    test "returns the error when Discord refuses it" do
      expect(AlexClaw.Gateway.Discord.APIMock, :create_message, fn _, _ ->
        {:error, %{status_code: 403, response: %{message: "Missing Access"}}}
      end)

      assert {:error, reason} = Discord.send_message("hello", [])
      assert inspect(reason) =~ "Missing Access"
    end

    test "with no channel configured, it is an error and nothing is sent" do
      insert_setting("discord.channel_id", "", type: "string", category: "discord")

      stub(AlexClaw.Gateway.Discord.APIMock, :create_message, fn _, _ ->
        flunk("sent with no channel")
      end)

      assert {:error, :no_channel_id} = Discord.send_message("hello", [])
    end
  end

  describe "discord_notify" do
    test "delivered only when Discord accepted it" do
      expect(AlexClaw.Gateway.Discord.APIMock, :create_message, fn _, _ -> {:ok, %{id: 1}} end)
      assert {:ok, "hello", :on_delivered} = DiscordNotify.run(%{input: "hello", config: %{}})
    end

    test "a refused send is an error, not delivered" do
      expect(AlexClaw.Gateway.Discord.APIMock, :create_message, fn _, _ ->
        {:error, :rate_limited}
      end)

      assert {:error, _} = DiscordNotify.run(%{input: "hello", config: %{}})
    end

    # Long messages go in chunks; one refused chunk means the message did not
    # arrive whole.
    test "a long message with one refused chunk is an error" do
      long = String.duplicate("x", 4500)

      AlexClaw.Gateway.Discord.APIMock
      |> expect(:create_message, fn _, _ -> {:ok, %{id: 1}} end)
      |> expect(:create_message, fn _, _ -> {:error, :rate_limited} end)
      |> stub(:create_message, fn _, _ -> {:ok, %{id: 2}} end)

      assert {:error, _} = DiscordNotify.run(%{input: long, config: %{}})
    end
  end
end
