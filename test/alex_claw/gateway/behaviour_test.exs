defmodule AlexClaw.Gateway.BehaviourTest do
  use ExUnit.Case, async: true

  alias AlexClaw.Gateway.Behaviour

  describe "behaviour callbacks" do
    test "defines send_message callback" do
      callbacks = Behaviour.behaviour_info(:callbacks)
      assert {:send_message, 2} in callbacks
    end

    test "defines send_html callback" do
      callbacks = Behaviour.behaviour_info(:callbacks)
      assert {:send_html, 2} in callbacks
    end

    test "defines send_photo callback" do
      callbacks = Behaviour.behaviour_info(:callbacks)
      assert {:send_photo, 3} in callbacks
    end

    test "defines name callback" do
      callbacks = Behaviour.behaviour_info(:callbacks)
      assert {:name, 0} in callbacks
    end

    test "defines configured? callback" do
      callbacks = Behaviour.behaviour_info(:callbacks)
      assert {:configured?, 0} in callbacks
    end

    test "Telegram implements the behaviour" do
      callbacks = Behaviour.behaviour_info(:callbacks)
      for {func, arity} <- callbacks do
        assert function_exported?(AlexClaw.Gateway.Telegram, func, arity),
          "Telegram missing #{func}/#{arity}"
      end
    end

    test "Discord implements the behaviour" do
      Code.ensure_loaded!(AlexClaw.Gateway.Discord)
      callbacks = Behaviour.behaviour_info(:callbacks)
      for {func, arity} <- callbacks do
        assert function_exported?(AlexClaw.Gateway.Discord, func, arity),
          "Discord missing #{func}/#{arity}"
      end
    end
  end
end
