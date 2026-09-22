defmodule AlexClaw.LLM.EmbeddingTest do
  @moduledoc """
  Which model embeds: `embedding.model` when set, else the provider's own
  default. A fresh install with only Ollama used to send Gemini's model name to
  Ollama and fail every embedding.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.LLM
  alias AlexClaw.LLM.Embedding

  defp provider(name, type) do
    {:ok, p} =
      LLM.create_provider(%{
        name: name,
        type: type,
        tier: "local",
        model: "m",
        host: "http://h",
        enabled: true
      })

    p
  end

  test "empty embedding.model means the provider's default" do
    {:ok, _} = AlexClaw.Config.set("embedding.model", "")
    assert Embedding.model_for(provider("o", "ollama")) == "nomic-embed-text"
    assert Embedding.model_for(provider("g", "gemini")) == "gemini-embedding-001"
    assert Embedding.model_for(provider("c", "openai_compatible")) == nil
  end

  test "a configured model is used whatever the provider" do
    {:ok, _} = AlexClaw.Config.set("embedding.model", "my-embedder")
    assert Embedding.model_for(provider("o", "ollama")) == "my-embedder"
  end

  test "the detected provider decides the default the staleness checks stamp" do
    {:ok, _} = AlexClaw.Config.set("embedding.model", "")
    provider("only-ollama", "ollama")
    assert Embedding.model() == "nomic-embed-text"
  end

  test "an OpenAI-compatible provider without a model name cannot embed" do
    {:ok, _} = AlexClaw.Config.set("embedding.model", "")
    provider("lmstudio", "openai_compatible")
    assert LLM.embed("text") == {:error, {:no_embedding_model, "lmstudio"}}
  end

  test "no provider, no embedding" do
    assert Embedding.provider() == {:error, :no_embedding_provider}
    assert Embedding.model() == nil
  end
end
