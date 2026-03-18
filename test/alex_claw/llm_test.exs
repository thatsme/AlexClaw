defmodule AlexClaw.LLMTest do
  use AlexClaw.DataCase, async: false

  alias AlexClaw.LLM

  # Helper to create a provider with sensible defaults
  defp create_test_provider(attrs \\ %{}) do
    defaults = %{
      name: "test_provider_#{System.unique_integer([:positive])}",
      type: "openai_compatible",
      host: "http://localhost:9999",
      model: "test-model",
      tier: "light",
      enabled: true,
      priority: 50
    }

    {:ok, provider} = LLM.create_provider(Map.merge(defaults, attrs))
    provider
  end

  describe "list_providers/0" do
    test "returns empty list when no providers exist" do
      assert LLM.list_providers() == []
    end

    test "returns providers ordered by tier, priority, name" do
      p1 = create_test_provider(%{name: "Zeta", tier: "light", priority: 10})
      p2 = create_test_provider(%{name: "Alpha", tier: "light", priority: 20})
      p3 = create_test_provider(%{name: "Beta", tier: "medium", priority: 10})

      providers = LLM.list_providers()
      ids = Enum.map(providers, & &1.id)
      assert ids == [p1.id, p2.id, p3.id]
    end

    test "includes disabled providers" do
      create_test_provider(%{enabled: true})
      create_test_provider(%{enabled: false})

      assert length(LLM.list_providers()) == 2
    end
  end

  describe "list_provider_choices/0" do
    test "auto is always first" do
      [first | _] = LLM.list_provider_choices()
      assert first.value == "auto"
      assert first.group == "auto"
    end

    test "includes providers from DB" do
      create_test_provider(%{name: "My LLM", model: "cool-model"})

      choices = LLM.list_provider_choices()
      values = Enum.map(choices, & &1.value)
      assert "My LLM" in values
    end

    test "marks disabled providers in label" do
      create_test_provider(%{name: "Disabled One", enabled: false})

      choices = LLM.list_provider_choices()
      disabled = Enum.find(choices, &(&1.value == "Disabled One"))
      assert disabled.label =~ "[disabled]"
    end

    test "returns maps with value, label, group" do
      create_test_provider()

      for choice <- LLM.list_provider_choices() do
        assert Map.has_key?(choice, :value)
        assert Map.has_key?(choice, :label)
        assert Map.has_key?(choice, :group)
      end
    end
  end

  describe "provider CRUD" do
    test "create_provider with valid attrs" do
      {:ok, p} =
        LLM.create_provider(%{
          name: "my_provider",
          type: "openai_compatible",
          host: "https://api.example.com",
          model: "gpt-4",
          tier: "medium",
          priority: 50
        })

      assert p.name == "my_provider"
      assert p.type == "openai_compatible"
      assert p.enabled == true
    end

    test "create_provider without host (cloud provider)" do
      {:ok, p} =
        LLM.create_provider(%{
          name: "cloud_llm",
          type: "gemini",
          model: "gemini-2.0-flash",
          tier: "light",
          api_key: "test-key"
        })

      assert p.host == nil
    end

    test "create_provider with priority" do
      {:ok, p} =
        LLM.create_provider(%{
          name: "prioritized",
          type: "ollama",
          host: "http://localhost:11434",
          model: "llama3",
          tier: "local",
          priority: 5
        })

      assert p.priority == 5
    end

    test "update_provider" do
      p = create_test_provider()
      {:ok, updated} = LLM.update_provider(p, %{model: "new-model"})
      assert updated.model == "new-model"
    end

    test "delete_provider" do
      p = create_test_provider()
      {:ok, _} = LLM.delete_provider(p)
      assert {:error, :not_found} = LLM.get_provider(p.id)
    end

    test "get_provider returns {:ok, provider}" do
      p = create_test_provider()
      assert {:ok, found} = LLM.get_provider(p.id)
      assert found.id == p.id
    end

    test "get_provider returns error for missing ID" do
      assert {:error, :not_found} = LLM.get_provider(999_999)
    end

    test "get_provider! raises on missing ID" do
      assert_raise Ecto.NoResultsError, fn -> LLM.get_provider!(999_999) end
    end

    test "create_provider rejects missing required fields" do
      assert {:error, %Ecto.Changeset{}} = LLM.create_provider(%{})
    end

    test "create_provider rejects invalid tier" do
      assert {:error, cs} =
               LLM.create_provider(%{
                 name: "bad_tier",
                 type: "ollama",
                 host: "http://localhost",
                 model: "llama3",
                 tier: "invalid_tier"
               })

      assert %Ecto.Changeset{valid?: false} = cs
    end

    test "create_provider rejects invalid type" do
      assert {:error, cs} =
               LLM.create_provider(%{
                 name: "bad_type",
                 type: "invalid_type",
                 host: "http://localhost",
                 model: "llama3",
                 tier: "light"
               })

      assert %Ecto.Changeset{valid?: false} = cs
    end

    test "create_provider enforces unique name" do
      create_test_provider(%{name: "unique_name"})

      assert {:error, cs} =
               LLM.create_provider(%{
                 name: "unique_name",
                 type: "ollama",
                 host: "http://localhost",
                 model: "llama3",
                 tier: "local"
               })

      assert %Ecto.Changeset{} = cs
    end

    test "delete_provider twice raises" do
      p = create_test_provider()
      {:ok, _} = LLM.delete_provider(p)
      assert_raise Ecto.StaleEntryError, fn -> LLM.delete_provider(p) end
    end
  end

  describe "complete/2 with no providers" do
    test "returns error when no models available" do
      assert {:error, _} = LLM.complete("test prompt", tier: :heavy)
    end

    test "returns error for all tiers" do
      for tier <- [:light, :medium, :heavy, :local] do
        assert {:error, _} = LLM.complete("test", tier: tier)
      end
    end

    test "returns error for unknown explicit provider" do
      assert {:error, {:unknown_provider, "nonexistent"}} =
               LLM.complete("test", provider: "nonexistent")
    end

    test "auto provider string behaves like nil" do
      result_auto = LLM.complete("test", provider: "auto", tier: :heavy)
      result_nil = LLM.complete("test", tier: :heavy)
      assert {:error, _} = result_auto
      assert {:error, _} = result_nil
    end

    test "empty provider string behaves like nil" do
      assert {:error, _} = LLM.complete("test", provider: "")
    end
  end

  describe "complete/2 with provider selection" do
    test "selects enabled provider by name" do
      create_test_provider(%{name: "Named Provider", host: "http://localhost:9999"})

      # Will fail to connect but should resolve the provider
      result = LLM.complete("test", provider: "Named Provider")
      assert {:error, _} = result
      # Should NOT be :unknown_provider — it was found
      refute match?({:error, {:unknown_provider, _}}, result)
    end

    test "skips disabled provider by name" do
      create_test_provider(%{name: "Disabled One", enabled: false})

      assert {:error, {:unknown_provider, "Disabled One"}} =
               LLM.complete("test", provider: "Disabled One")
    end

    test "respects daily limit" do
      p = create_test_provider(%{tier: "light", daily_limit: 0})

      # Provider exists but at limit
      result = LLM.complete("test", tier: :light)
      assert {:error, :all_providers_at_limit} = result
    end

    test "unlimited when daily_limit is nil" do
      create_test_provider(%{tier: "medium", daily_limit: nil, host: "http://localhost:9999"})

      result = LLM.complete("test", tier: :medium)
      # Should find the provider (will fail on network, not on limit)
      refute match?({:error, :no_available_model}, result)
      refute match?({:error, :all_providers_at_limit}, result)
    end
  end

  describe "usage_today/1" do
    test "returns 0 for unknown provider" do
      assert LLM.usage_today(999_999) == 0
    end

    test "returns 0 for new provider" do
      p = create_test_provider()
      assert LLM.usage_today(p.id) == 0
    end
  end

  describe "embed/2" do
    test "returns error when no providers exist" do
      assert {:error, :no_embedding_provider} = LLM.embed("test text")
    end

    test "auto-detects Gemini provider for embeddings" do
      bypass = Bypass.open()
      vector = List.duplicate(0.1, 768)

      Bypass.expect_once(
        bypass,
        "POST",
        "/v1beta/models/text-embedding-004:embedContent",
        fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!(%{"embedding" => %{"values" => vector}}))
        end
      )

      Application.put_env(:alex_claw, :embedding_base_url, "http://localhost:#{bypass.port}")

      create_test_provider(%{
        name: "Gemini Flash",
        type: "gemini",
        model: "gemini-2.0-flash",
        api_key: "test-key",
        tier: "light"
      })

      assert {:ok, result} = LLM.embed("test text")
      assert length(result) == 768

      Application.delete_env(:alex_claw, :embedding_base_url)
    end

    test "auto-detects Ollama when no Gemini available" do
      bypass = Bypass.open()
      vector = List.duplicate(0.2, 768)

      Bypass.expect_once(bypass, "POST", "/api/embed", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"embeddings" => [vector]}))
      end)

      create_test_provider(%{
        name: "Local Ollama",
        type: "ollama",
        host: "http://localhost:#{bypass.port}",
        model: "nomic-embed-text",
        tier: "local"
      })

      assert {:ok, result} = LLM.embed("test text")
      assert length(result) == 768
    end

    test "uses configured embedding provider" do
      bypass = Bypass.open()
      vector = List.duplicate(0.3, 768)

      Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"data" => [%{"embedding" => vector}]}))
      end)

      create_test_provider(%{
        name: "Custom Embedder",
        type: "openai_compatible",
        host: "http://localhost:#{bypass.port}",
        model: "embed-model",
        tier: "light"
      })

      AlexClaw.Config.set("embedding.provider", "Custom Embedder")

      assert {:ok, result} = LLM.embed("test text")
      assert length(result) == 768
    end

    test "returns error when API fails" do
      bypass = Bypass.open()

      Bypass.expect_once(
        bypass,
        "POST",
        "/v1beta/models/text-embedding-004:embedContent",
        fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(500, Jason.encode!(%{"error" => "internal"}))
        end
      )

      Application.put_env(:alex_claw, :embedding_base_url, "http://localhost:#{bypass.port}")

      create_test_provider(%{
        name: "Failing Gemini",
        type: "gemini",
        model: "gemini-2.0-flash",
        api_key: "test-key",
        tier: "light"
      })

      assert {:error, {:gemini_embed, 500, _}} = LLM.embed("test text")

      Application.delete_env(:alex_claw, :embedding_base_url)
    end

    test "returns error for Anthropic provider (no embedding API)" do
      create_test_provider(%{
        name: "Claude",
        type: "anthropic",
        model: "claude-haiku",
        api_key: "test-key",
        tier: "light"
      })

      AlexClaw.Config.set("embedding.provider", "Claude")

      assert {:error, :anthropic_no_embeddings} = LLM.embed("test text")
    end
  end

  describe "Provider schema" do
    test "default priority is 100" do
      {:ok, p} =
        LLM.create_provider(%{
          name: "default_priority",
          type: "ollama",
          host: "http://localhost",
          model: "llama3",
          tier: "local"
        })

      assert p.priority == 100
    end

    test "default enabled is true" do
      {:ok, p} =
        LLM.create_provider(%{
          name: "default_enabled",
          type: "ollama",
          host: "http://localhost",
          model: "llama3",
          tier: "local"
        })

      assert p.enabled == true
    end

    test "rejects negative priority" do
      assert {:error, cs} =
               LLM.create_provider(%{
                 name: "neg_priority",
                 type: "ollama",
                 host: "http://localhost",
                 model: "llama3",
                 tier: "local",
                 priority: -1
               })

      assert %Ecto.Changeset{valid?: false} = cs
    end
  end
end
