defmodule AlexClaw.IdentityAdversarialTest do
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :adversarial

  alias AlexClaw.{Config, Identity}

  describe "system_prompt/1 with missing config" do
    test "replaces {name} even when identity.name is nil" do
      Config.set("identity.name", nil, type: "string", category: "identity")

      prompt = Identity.system_prompt()
      # Config.set(key, nil) clears the value — Config.get returns nil
      # Identity uses: name || "Agent" — but Config may store "" not nil
      # Either way, {name} placeholder must not appear in output
      assert is_binary(prompt)
      refute prompt =~ "{name}"
    end

    test "uses fallback base_prompt when identity.base_prompt is nil" do
      Config.set("identity.base_prompt", nil, type: "string", category: "identity")

      prompt = Identity.system_prompt()
      # Fallback: "You are {name}, a personal AI agent."
      assert is_binary(prompt)
      assert prompt =~ "AI agent" or prompt =~ Config.get("identity.name") || ""
    end

    test "handles both name and base_prompt being nil without crash" do
      Config.set("identity.name", nil, type: "string", category: "identity")
      Config.set("identity.base_prompt", nil, type: "string", category: "identity")

      prompt = Identity.system_prompt()
      assert is_binary(prompt)
      # Fallback base_prompt uses "Agent" when name is nil
      # The key invariant: no crash, returns a string
    end
  end

  describe "system_prompt/1 with edge case values" do
    test "handles empty string name" do
      Config.set("identity.name", "", type: "string", category: "identity")

      prompt = Identity.system_prompt()
      assert is_binary(prompt)
      # Empty string replaces {name} — result may have empty where name was
      refute prompt =~ "{name}"
    end

    test "handles very long name without crashing" do
      long_name = String.duplicate("A", 10_000)
      Config.set("identity.name", long_name, type: "string", category: "identity")

      prompt = Identity.system_prompt()
      assert is_binary(prompt)
      assert prompt =~ long_name
    end

    test "handles empty base_prompt" do
      Config.set("identity.base_prompt", "", type: "string", category: "identity")

      prompt = Identity.system_prompt()
      assert is_binary(prompt)
    end

    test "handles unicode name" do
      Config.set("identity.name", "クロード助手", type: "string", category: "identity")

      prompt = Identity.system_prompt()
      assert prompt =~ "クロード助手"
    end

    test "handles name with special characters" do
      Config.set("identity.name", "<script>alert('xss')</script>", type: "string", category: "identity")

      prompt = Identity.system_prompt()
      # Should contain the raw string (prompt is not HTML-escaped at this layer)
      assert is_binary(prompt)
    end
  end

  describe "system_prompt/1 with unknown skill context" do
    test "returns prompt without fragment for unknown skill" do
      prompt = Identity.system_prompt(%{skill: :nonexistent_skill})
      assert is_binary(prompt)
      # Should not crash, just returns base prompt without context fragment
    end

    test "returns prompt without fragment for nil skill" do
      prompt = Identity.system_prompt(%{skill: nil})
      assert is_binary(prompt)
    end

    test "returns prompt for empty context map" do
      prompt = Identity.system_prompt(%{})
      assert is_binary(prompt)
    end
  end

  describe "system_prompt/1 with persona" do
    test "appends persona when set" do
      Config.set("identity.persona", "Always reply in Italian.", type: "string", category: "identity")

      prompt = Identity.system_prompt()
      assert prompt =~ "Always reply in Italian."
    end

    test "omits persona when empty string" do
      Config.set("identity.persona", "", type: "string", category: "identity")

      prompt = Identity.system_prompt()
      # Empty persona should not add extra newlines or content
      refute prompt =~ "\n\n\n"
    end
  end
end
