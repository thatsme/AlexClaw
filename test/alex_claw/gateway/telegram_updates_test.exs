defmodule AlexClaw.Gateway.TelegramUpdatesTest do
  @moduledoc """
  A message that crashes its handler must not come back
  (reports/GATEWAY_CRASH_2026-09-23.md §5).

  The gateway dispatched each update inside its own process and moved its
  offset only after the whole batch returned. A crash lost the new offset,
  the restarted gateway started again from 0, and Telegram re-delivered the
  message that had crashed it: once per second, until the application
  stopped.

  The batch handling is now a function the tests can call:
  `AlexClaw.Gateway.Telegram.process_updates(updates, offset, dispatch)`
  returns the next offset. Each update is handled on its own; an exception
  while handling one is logged, not raised, and does not stop the rest of the
  batch; the returned offset is past every update in it. Delivery is at most
  once: a message that crashed is acknowledged, not retried.

  `dispatch` is the function called with each `%AlexClaw.Message{}`; the
  gateway passes `&AlexClaw.Dispatcher.dispatch/1`.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  import ExUnit.CaptureLog

  alias AlexClaw.Gateway.Telegram
  alias AlexClaw.Message

  @chat 4242

  setup do
    # Updates are only accepted from the configured chat.
    insert_setting("telegram.chat_id", to_string(@chat), type: "string", category: "telegram")
    :ok
  end

  # Not `update/2`: DataCase imports Ecto.Query, whose `update` macro would
  # take the call.
  defp tg_update(id, text) do
    %{
      "update_id" => id,
      "message" => %{
        "message_id" => id,
        "date" => System.os_time(:second),
        "text" => text,
        "chat" => %{"id" => @chat, "type" => "private"},
        "from" => %{"id" => @chat, "first_name" => "Test"}
      }
    }
  end

  defp recording_dispatch(test_pid, poison) do
    fn %Message{text: text} ->
      send(test_pid, {:dispatched, text})
      if text == poison, do: raise("boom from #{text}"), else: :ok
    end
  end

  test "the offset moves past every update" do
    offset =
      Telegram.process_updates(
        [tg_update(10, "a"), tg_update(11, "b")],
        0,
        recording_dispatch(self(), nil)
      )

    assert offset == 12
    assert_received {:dispatched, "a"}
    assert_received {:dispatched, "b"}
  end

  test "an update that crashes its handler is logged, acknowledged, and not retried" do
    log =
      capture_log(fn ->
        offset =
          Telegram.process_updates(
            [tg_update(20, "before"), tg_update(21, "poison"), tg_update(22, "after")],
            0,
            recording_dispatch(self(), "poison")
          )

        send(self(), {:offset, offset})
      end)

    assert_received {:offset, 23}
    assert_received {:dispatched, "before"}
    assert_received {:dispatched, "poison"}
    assert_received {:dispatched, "after"}, "the batch stopped at the crash"
    assert log =~ "boom from poison"
  end

  test "each update is handled once, even when a later one crashes" do
    capture_log(fn ->
      Telegram.process_updates(
        [tg_update(30, "first"), tg_update(31, "poison")],
        0,
        recording_dispatch(self(), "poison")
      )
    end)

    assert_received {:dispatched, "first"}
    refute_received {:dispatched, "first"}
  end

  test "an empty batch leaves the offset where it was" do
    assert Telegram.process_updates([], 57, recording_dispatch(self(), nil)) == 57
  end

  test "an exit or a throw in a handler is contained too" do
    for kind <- [:exit, :throw] do
      dispatch = fn _ -> if kind == :exit, do: exit(:boom), else: throw(:boom) end

      capture_log(fn ->
        assert Telegram.process_updates([tg_update(40, "x")], 0, dispatch) == 41
      end)
    end
  end
end
