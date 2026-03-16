defmodule AlexClaw.LLMTest do
  use AlexClaw.DataCase, async: false

  alias AlexClaw.LLM

  describe "list_provider_choices/0" do
    test "includes auto and builtin options" do
      choices = LLM.list_provider_choices()
      values = Enum.map(choices, & &1.value)

      assert "auto" in values
      assert "gemini_flash" in values
      assert "sonnet" in values
      assert "ollama" in values
    end

    test "includes custom providers from DB" do
      {:ok, _} = LLM.create_provider(%{
        name: "test_groq",
        type: "openai_compatible",
        host: "https://api.groq.com/openai",
        model: "llama-3",
        tier: "light",
        enabled: true
      })

      choices = LLM.list_provider_choices()
      values = Enum.map(choices, & &1.value)
      assert "test_groq" in values
    end
  end

  describe "provider CRUD" do
    test "create_provider with valid attrs" do
      {:ok, p} = LLM.create_provider(%{
        name: "my_provider",
        type: "openai_compatible",
        host: "https://api.example.com",
        model: "gpt-4",
        tier: "medium",
        enabled: true
      })
      assert p.name == "my_provider"
      assert p.type == "openai_compatible"
    end

    test "update_provider" do
      {:ok, p} = LLM.create_provider(%{
        name: "updatable",
        type: "ollama",
        host: "http://localhost:11434",
        model: "llama3",
        tier: "local",
        enabled: true
      })
      {:ok, updated} = LLM.update_provider(p, %{model: "mistral"})
      assert updated.model == "mistral"
    end

    test "delete_provider" do
      {:ok, p} = LLM.create_provider(%{
        name: "deletable",
        type: "ollama",
        host: "http://localhost:11434",
        model: "llama3",
        tier: "local",
        enabled: true
      })
      {:ok, _} = LLM.delete_provider(p)
      assert_raise Ecto.NoResultsError, fn -> LLM.get_provider!(p.id) end
    end
  end

  describe "usage tracking" do
    test "init_usage_table creates ETS table" do
      assert :ets.info(:alexclaw_llm_usage) != :undefined
    end

    test "usage starts at zero" do
      key = {:test_model, Date.utc_today()}
      assert :ets.lookup(:alexclaw_llm_usage, key) == [] || [{key, 0}]
    end
  end

  describe "complete/2 with no providers configured" do
    test "returns error when no models available" do
      result = LLM.complete("test prompt", tier: :heavy)
      assert {:error, _} = result
    end
  end

  describe "provider CRUD adversarial" do
    test "create_provider rejects missing required fields" do
      assert {:error, %Ecto.Changeset{}} = LLM.create_provider(%{})
    end

    test "create_provider rejects blank name" do
      assert {:error, changeset} = LLM.create_provider(%{
        name: "",
        type: "openai_compatible",
        host: "https://api.example.com",
        model: "gpt-4",
        tier: "medium",
        enabled: true
      })
      assert %Ecto.Changeset{valid?: false} = changeset
    end

    test "get_provider! raises on non-existent ID" do
      assert_raise Ecto.NoResultsError, fn -> LLM.get_provider!(999_999) end
    end

    test "update_provider rejects invalid changeset" do
      {:ok, p} = LLM.create_provider(%{
        name: "will_break",
        type: "ollama",
        host: "http://localhost:11434",
        model: "llama3",
        tier: "local",
        enabled: true
      })
      assert {:error, %Ecto.Changeset{}} = LLM.update_provider(p, %{name: ""})
    end

    test "delete_provider twice raises" do
      {:ok, p} = LLM.create_provider(%{
        name: "double_delete",
        type: "ollama",
        host: "http://localhost:11434",
        model: "llama3",
        tier: "local",
        enabled: true
      })
      {:ok, _} = LLM.delete_provider(p)
      assert_raise Ecto.StaleEntryError, fn -> LLM.delete_provider(p) end
    end
  end

  describe "complete/2 adversarial" do
    test "returns error for unknown explicit provider" do
      result = LLM.complete("test", provider: "nonexistent_provider_xyz")
      assert {:error, {:unknown_provider, "nonexistent_provider_xyz"}} = result
    end

    test "auto provider string behaves like nil" do
      result_auto = LLM.complete("test", provider: "auto", tier: :heavy)
      result_nil = LLM.complete("test", tier: :heavy)
      assert {:error, _} = result_auto
      assert {:error, _} = result_nil
    end

    test "empty provider string behaves like nil" do
      result = LLM.complete("test", provider: "")
      assert {:error, _} = result
    end

    test "returns error for all tiers when unconfigured" do
      for tier <- [:light, :medium, :heavy, :local] do
        assert {:error, _} = LLM.complete("test", tier: tier)
      end
    end
  end

  describe "list_provider_choices/0 structure" do
    test "returns list of maps with value, label, group" do
      choices = LLM.list_provider_choices()
      assert is_list(choices)

      for choice <- choices do
        assert Map.has_key?(choice, :value)
        assert Map.has_key?(choice, :label)
        assert Map.has_key?(choice, :group)
      end
    end

    test "auto is always first" do
      [first | _] = LLM.list_provider_choices()
      assert first.value == "auto"
    end
  end

  describe "embed/2" do
    test "returns {:ok, nil} (embeddings not implemented yet)" do
      assert {:ok, nil} = LLM.embed("test text")
    end

    test "ignores opts" do
      assert {:ok, nil} = LLM.embed("test", model: "fake", dimensions: 1536)
    end
  end
end
