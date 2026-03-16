defmodule AlexClaw.MessageTest do
  use ExUnit.Case, async: true

  alias AlexClaw.Message

  describe "struct" do
    test "creates with all fields" do
      now = DateTime.utc_now()

      msg = %Message{
        text: "hello",
        chat_id: 12345,
        from: "Alessio",
        timestamp: now,
        raw: %{"update_id" => 1}
      }

      assert msg.text == "hello"
      assert msg.chat_id == 12345
      assert msg.from == "Alessio"
      assert msg.timestamp == now
      assert msg.raw == %{"update_id" => 1}
    end

    test "defaults to nil fields" do
      msg = %Message{}
      assert msg.text == nil
      assert msg.chat_id == nil
      assert msg.from == nil
      assert msg.timestamp == nil
      assert msg.raw == nil
    end
  end
end
