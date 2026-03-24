defmodule AlexClaw.LLM.ClientTest do
  use AlexClaw.DataCase, async: false

  alias AlexClaw.LLM.{Client, Provider}

  defp build_provider(attrs \\ %{}) do
    defaults = %Provider{
      id: 1,
      name: "test",
      type: "openai_compatible",
      host: "http://localhost:9999",
      model: "test-model",
      api_key: "test-key",
      headers: %{},
      enabled: true,
      priority: 50,
      tier: "light"
    }

    struct(defaults, attrs)
  end

  describe "resolve_api_key/1" do
    test "returns provider api_key when set" do
      provider = build_provider(%{api_key: "my-secret-key"})
      assert Client.resolve_api_key(provider) == "my-secret-key"
    end

    test "falls back to config for gemini provider with no key" do
      insert_setting("llm.gemini_api_key", "config-gemini-key", type: "string", category: "llm")
      provider = build_provider(%{type: "gemini", api_key: nil})
      assert Client.resolve_api_key(provider) == "config-gemini-key"
    end

    test "falls back to config for anthropic provider with no key" do
      insert_setting("llm.anthropic_api_key", "config-anthropic-key", type: "string", category: "llm")
      provider = build_provider(%{type: "anthropic", api_key: nil})
      assert Client.resolve_api_key(provider) == "config-anthropic-key"
    end

    test "returns empty string for unknown type with no key" do
      provider = build_provider(%{type: "ollama", api_key: nil})
      assert Client.resolve_api_key(provider) == ""
    end

    test "returns empty string when provider key is empty" do
      provider = build_provider(%{type: "gemini", api_key: ""})
      # Empty string falls through to config lookup
      result = Client.resolve_api_key(provider)
      assert is_binary(result)
    end
  end

  describe "call_provider/3" do
    test "returns error for gemini without api key" do
      provider = build_provider(%{type: "gemini", api_key: nil})
      assert {:error, :api_key_not_set} = Client.call_provider(provider, "hello", nil)
    end

    test "returns error for anthropic without api key" do
      provider = build_provider(%{type: "anthropic", api_key: nil})
      assert {:error, :api_key_not_set} = Client.call_provider(provider, "hello", nil)
    end

    test "returns error for ollama without host" do
      provider = build_provider(%{type: "ollama", host: nil})
      assert {:error, :host_not_set} = Client.call_provider(provider, "hello", nil)
    end

    test "returns error for ollama with empty host" do
      provider = build_provider(%{type: "ollama", host: ""})
      assert {:error, :host_not_set} = Client.call_provider(provider, "hello", nil)
    end

    test "returns error for openai_compatible without host" do
      provider = build_provider(%{type: "openai_compatible", host: ""})
      assert {:error, :host_not_set} = Client.call_provider(provider, "hello", nil)
    end

    test "returns error for custom type without host" do
      provider = build_provider(%{type: "custom", host: ""})
      assert {:error, :host_not_set} = Client.call_provider(provider, "hello", nil)
    end
  end

  describe "call_embedding/3" do
    test "returns error for anthropic (not supported)" do
      provider = build_provider(%{type: "anthropic"})
      assert {:error, :anthropic_no_embeddings} = Client.call_embedding(provider, "text", "model")
    end

    test "returns error for gemini without api key" do
      provider = build_provider(%{type: "gemini", api_key: nil})
      assert {:error, :api_key_not_set} = Client.call_embedding(provider, "text", "model")
    end

    test "returns error for ollama without host" do
      provider = build_provider(%{type: "ollama", host: ""})
      assert {:error, :host_not_set} = Client.call_embedding(provider, "text", "model")
    end

    test "returns error for openai_compatible without host" do
      provider = build_provider(%{type: "openai_compatible", host: ""})
      assert {:error, :host_not_set} = Client.call_embedding(provider, "text", "model")
    end
  end
end
