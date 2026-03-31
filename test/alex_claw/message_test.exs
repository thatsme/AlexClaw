defmodule AlexClaw.MessageTest do
  use ExUnit.Case, async: true
  @moduletag :unit

  alias AlexClaw.Message

  describe "struct" do
    test "creates with all fields" do
      now = DateTime.utc_now()

      msg = %Message{
        text: "hello",
        chat_id: 12345,
        from: "Alessio",
        timestamp: now,
        raw: %{"update_id" => 1},
        gateway: :telegram
      }

      assert msg.text == "hello"
      assert msg.chat_id == 12345
      assert msg.from == "Alessio"
      assert msg.timestamp == now
      assert msg.raw == %{"update_id" => 1}
    end

    test "enforces required keys" do
      assert_raise ArgumentError, ~r/the following keys must also be given/, fn ->
        struct!(Message, text: "hello")
      end
    end

    test "defaults optional fields to nil" do
      msg = %Message{chat_id: 1, timestamp: DateTime.utc_now(), raw: %{}, gateway: :test}
      assert msg.text == nil
      assert msg.from == nil
    end
  end
end
