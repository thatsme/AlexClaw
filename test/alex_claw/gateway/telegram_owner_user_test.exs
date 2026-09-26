defmodule AlexClaw.Gateway.TelegramOwnerUserTest do
  @moduledoc """
  On Telegram, as on Discord, the owner is a user (S8 M10; ruling S9).

  The owner chat (`telegram.chat_id`) may be a group, whose every member
  could otherwise command the agent. A message is answered only when it comes
  from the owner chat and from the owner user (`telegram.owner_user_id`),
  both set in the admin UI: in a group, only that user's messages count. With
  no owner user set, nothing is answered.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.{Dispatcher, Message}

  @group "-100200300"
  @owner "555000111"

  setup do
    insert_setting("telegram.chat_id", @group, type: "string", category: "telegram")
    :ok
  end

  defp message(user_id) do
    %Message{
      text: "/ping",
      chat_id: @group,
      user_id: user_id,
      from: "someone",
      timestamp: DateTime.utc_now(),
      raw: %{},
      gateway: :telegram
    }
  end

  test "another member of the owner group is ignored" do
    insert_setting("telegram.owner_user_id", @owner, type: "string", category: "telegram")

    assert Dispatcher.dispatch(message("999888777")) == :ignored
  end

  test "with no owner user set, the owner chat is ignored" do
    assert Dispatcher.dispatch(message(@owner)) == :ignored
  end

  test "the owner user in the owner chat is answered" do
    insert_setting("telegram.owner_user_id", @owner, type: "string", category: "telegram")

    refute Dispatcher.dispatch(message(@owner)) == :ignored
  end
end
