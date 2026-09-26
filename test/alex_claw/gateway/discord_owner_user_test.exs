defmodule AlexClaw.Gateway.DiscordOwnerUserTest do
  @moduledoc """
  On Discord the owner is a user, in the owner channel (S8 M10; T1/T3).

  A channel has members: its id alone would let any of them command the
  agent. A message is answered only when it comes from the owner channel
  (`discord.channel_id`) and from the owner user (`discord.owner_user_id`),
  both set in the admin UI. With no owner user set, nothing is answered.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.{Dispatcher, Message}

  @channel "123456789"
  @owner "555000111"

  setup do
    insert_setting("discord.channel_id", @channel, type: "string", category: "discord")
    :ok
  end

  defp message(user_id) do
    %Message{
      text: "/ping",
      chat_id: @channel,
      user_id: user_id,
      from: "someone",
      timestamp: DateTime.utc_now(),
      raw: %{},
      gateway: :discord
    }
  end

  test "another member of the owner channel is ignored" do
    insert_setting("discord.owner_user_id", @owner, type: "string", category: "discord")

    assert Dispatcher.dispatch(message("999888777")) == :ignored
  end

  test "with no owner user set, the owner channel is ignored" do
    assert Dispatcher.dispatch(message(@owner)) == :ignored
  end

  test "the owner user in the owner channel is answered" do
    Application.put_env(:alex_claw, :discord_api, AlexClaw.Gateway.Discord.APIMock)
    on_exit(fn -> Application.delete_env(:alex_claw, :discord_api) end)
    Mox.set_mox_global()
    test_pid = self()

    Mox.stub(AlexClaw.Gateway.Discord.APIMock, :create_message, fn _channel, content ->
      send(test_pid, {:answered, content})
      {:ok, %{id: 1}}
    end)

    insert_setting("discord.owner_user_id", @owner, type: "string", category: "discord")

    refute Dispatcher.dispatch(message(@owner)) == :ignored
    assert_receive {:answered, "pong" <> _}, 2_000
  end
end
