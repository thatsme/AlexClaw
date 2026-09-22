defmodule AlexClaw.LLM.WindowTest do
  @moduledoc """
  Prompts are measured against each provider's context window before they are
  sent: Ollama cut a Forge prompt longer than its window silently, dropping the
  instruction that named the module, and the model wrote the wrong one.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.LLM
  alias AlexClaw.LLM.{Provider, Window}

  defp provider(attrs) do
    struct(Provider, Map.merge(%{name: "p", type: "ollama", model: "m", options: %{}}, attrs))
  end

  describe "a provider's window" do
    test "Ollama: num_ctx, else Ollama's own default" do
      assert Window.tokens(provider(%{options: %{"num_ctx" => 16_384}})) == 16_384
      assert Window.tokens(provider(%{})) == 4096
      assert Window.tokens(provider(%{options: nil})) == 4096
    end

    test "context_window overrides whatever the type implies" do
      assert Window.tokens(provider(%{options: %{"context_window" => 32_000, "num_ctx" => 8192}})) ==
               32_000

      assert Window.tokens(provider(%{options: %{"context_window" => "12000"}})) == 12_000
    end

    test "a value that is not a positive number is ignored" do
      for bad <- [0, -1, "abc", "", nil] do
        assert Window.tokens(provider(%{options: %{"num_ctx" => bad}})) == 4096
      end
    end

    test "Gemini and Anthropic have their published windows" do
      assert Window.tokens(provider(%{type: "gemini"})) == 1_000_000
      assert Window.tokens(provider(%{type: "anthropic"})) == 200_000
    end

    test "LM Studio reports the loaded model's context; other servers are unknown" do
      bypass = Bypass.open()

      Bypass.stub(bypass, "GET", "/api/v0/models", fn conn ->
        body = %{
          "data" => [
            %{"id" => "embedder", "type" => "embeddings", "loaded_context_length" => 2048},
            %{"id" => "qwen3-14b", "type" => "llm", "loaded_context_length" => 8192},
            %{"id" => "other", "type" => "llm", "loaded_context_length" => nil}
          ]
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      lm = %{type: "openai_compatible", tier: "local", host: "http://localhost:#{bypass.port}"}
      assert Window.tokens(provider(Map.put(lm, :model, "default"))) == 8192
      assert Window.tokens(provider(Map.put(lm, :model, "qwen3-14b"))) == 8192
      assert Window.tokens(provider(Map.put(lm, :model, "other"))) == nil

      Bypass.down(bypass)
      assert Window.tokens(provider(Map.put(lm, :model, "default"))) == nil
    end

    test "a server outside the local tier is not asked" do
      bypass = Bypass.open()

      Bypass.stub(bypass, "GET", "/api/v0/models", fn conn ->
        Plug.Conn.resp(conn, 500, "this server must not be asked")
      end)

      cloud = %{
        type: "openai_compatible",
        tier: "light",
        model: "default",
        host: "http://localhost:#{bypass.port}"
      }

      assert Window.tokens(provider(cloud)) == nil
    end

    test "the answer's reserve is num_predict or max_tokens, else 2048" do
      assert Window.reserve(provider(%{options: %{"num_predict" => 1000}})) == 1000
      assert Window.reserve(provider(%{options: %{"max_tokens" => 500}})) == 500
      assert Window.reserve(provider(%{})) == 2048
    end
  end

  describe "the router" do
    defp served(name, priority, bypass, options) do
      {:ok, _} =
        LLM.create_provider(%{
          name: name,
          type: "ollama",
          tier: "local",
          model: "m",
          host: "http://localhost:#{bypass.port}",
          enabled: true,
          priority: priority,
          options: options
        })

      Bypass.stub(bypass, "POST", "/api/chat", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"message" => %{"content" => "from #{name}"}}))
      end)
    end

    test "a prompt too large for the first provider is refused, not handed to the next" do
      small = Bypass.open()
      large = Bypass.open()
      served("small", 1, small, %{"num_ctx" => 4096})
      served("large", 2, large, %{"num_ctx" => 16_384})

      prompt = String.duplicate("word ", 3000)

      assert {:error, {:prompt_too_large, [%{provider: "small", window: 4096}]}} =
               LLM.complete(prompt, tier: :local)
    end

    test "a local LM Studio's loaded window is checked before the call" do
      lm = Bypass.open()

      {:ok, _} =
        LLM.create_provider(%{
          name: "lm",
          type: "openai_compatible",
          tier: "local",
          model: "default",
          host: "http://localhost:#{lm.port}",
          enabled: true,
          priority: 1
        })

      Bypass.stub(lm, "GET", "/api/v0/models", fn conn ->
        body = %{"data" => [%{"id" => "q", "type" => "llm", "loaded_context_length" => 8192}]}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      # No POST route: a call reaching the server would fail the test.
      assert {:error, {:prompt_too_large, [%{provider: "lm", window: 8192}]}} =
               LLM.complete(String.duplicate("word ", 5000), tier: :local)
    end

    test "a prompt no provider fits is refused, naming each window" do
      one = Bypass.open()
      served("only", 1, one, %{"num_ctx" => 4096})

      assert {:error,
              {:prompt_too_large, [%{provider: "only", window: 4096, prompt_tokens: needed}]}} =
               LLM.complete(String.duplicate("word ", 5000), tier: :local)

      assert needed > 4096
    end

    test "an oversized prompt to an Ollama provider is refused before the call" do
      ollama = Bypass.open()
      test = self()

      {:ok, _} =
        LLM.create_provider(%{
          name: "ollama",
          type: "ollama",
          tier: "local",
          model: "m",
          host: "http://localhost:#{ollama.port}",
          enabled: true,
          priority: 1,
          options: %{"num_ctx" => 8192, "num_predict" => 2048}
        })

      Bypass.stub(ollama, "POST", "/api/chat", fn conn ->
        send(test, :ollama_called)
        Plug.Conn.resp(conn, 200, ~s({"message": {"content": "must not be used"}}))
      end)

      assert {:error,
              {:prompt_too_large, [%{provider: "ollama", window: 8192, prompt_tokens: needed}]}} =
               LLM.complete(String.duplicate("word ", 5000), tier: :local)

      assert needed > 8192 - 2048
      refute_received :ollama_called
    end

    test "without num_ctx, an Ollama provider is measured against Ollama's default window" do
      ollama = Bypass.open()
      served("bare", 1, ollama, %{})

      assert {:error, {:prompt_too_large, [%{provider: "bare", window: 4096}]}} =
               LLM.complete(String.duplicate("word ", 3000), tier: :local)
    end

    test "a builder gets each provider's budget and trims to it" do
      one = Bypass.open()
      served("only", 1, one, %{"num_ctx" => 4096, "num_predict" => 1000})
      test = self()

      build = fn budget ->
        send(test, {:budget, budget})
        {:ok, "short"}
      end

      assert {:ok, "from only"} = LLM.complete_fitted(build, tier: :local, system: "sys")
      assert_received {:budget, budget}
      assert budget == 4096 - 1000 - Window.estimate("sys")
    end
  end
end
