defmodule AlexClaw.IdentityTest do
  use AlexClaw.DataCase, async: false

  alias AlexClaw.Identity

  setup do
    insert_setting("identity.name", "TestBot")
    insert_setting("identity.base_prompt", "You are {name}, an AI assistant.")
    insert_setting("identity.persona", "Be helpful and concise.")
    :ok
  end

  describe "system_prompt/1" do
    test "interpolates name into base prompt" do
      prompt = Identity.system_prompt()
      assert prompt =~ "You are TestBot"
    end

    test "includes persona" do
      prompt = Identity.system_prompt()
      assert prompt =~ "Be helpful and concise."
    end

    test "includes context fragment when skill provided" do
      insert_setting("prompts.context.research", "Focus on accuracy and citations.")
      prompt = Identity.system_prompt(%{skill: :research})
      assert prompt =~ "Focus on accuracy and citations."
    end

    test "works without context" do
      prompt = Identity.system_prompt(%{})
      assert prompt =~ "TestBot"
      refute prompt =~ "nil"
    end

    test "falls back to Agent when name not set" do
      :ets.delete(:alexclaw_config, "identity.name")
      insert_setting("identity.base_prompt", "You are {name}.")

      prompt = Identity.system_prompt()
      assert prompt =~ "You are Agent."
    end
  end
end
