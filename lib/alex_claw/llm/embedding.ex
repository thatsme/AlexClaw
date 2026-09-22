defmodule AlexClaw.LLM.Embedding do
  @moduledoc """
  Which provider embeds, and with which model — one answer, used by the write
  path (`AlexClaw.LLM.Real.embed/2`) and by Memory's and Knowledge's staleness
  checks, which stamp and compare the model name.

  The provider is `embedding.provider` when set, otherwise the first enabled
  Gemini, then Ollama, then OpenAI-compatible provider. The model is
  `embedding.model` when set; empty, it is the provider's own default
  (`gemini-embedding-001` on Gemini, `nomic-embed-text` on Ollama). An
  OpenAI-compatible provider has no default: its model has to be named.
  """

  import Ecto.Query

  alias AlexClaw.LLM.Provider
  alias AlexClaw.Repo

  @provider_defaults %{"gemini" => "gemini-embedding-001", "ollama" => "nomic-embed-text"}

  @doc "The provider that embeds: named in `opts[:provider]`, configured, or detected."
  @spec provider(keyword()) :: {:ok, Provider.t()} | {:error, term()}
  def provider(opts \\ []) do
    opts
    |> Keyword.get(:provider)
    |> blank_to(AlexClaw.Config.get("embedding.provider"))
    |> named_or_detected()
  end

  @doc "The model the resolved provider embeds with, or nil when none can be named."
  @spec model() :: String.t() | nil
  def model do
    case provider() do
      {:ok, provider} -> model_for(provider)
      _ -> configured_model()
    end
  end

  @doc "The model `provider` embeds with: `embedding.model`, or the provider's default."
  @spec model_for(Provider.t()) :: String.t() | nil
  def model_for(%Provider{type: type}),
    do: configured_model() || Map.get(@provider_defaults, type)

  defp configured_model do
    case AlexClaw.Config.get("embedding.model") do
      model when model in [nil, ""] -> nil
      model -> model
    end
  end

  defp blank_to(value, fallback) when value in [nil, ""], do: fallback
  defp blank_to(value, _fallback), do: value

  defp named_or_detected(name) when name in [nil, ""], do: detect()

  defp named_or_detected(name) do
    case Repo.one(from(p in Provider, where: p.name == ^name and p.enabled == true)) do
      nil -> {:error, {:unknown_provider, name}}
      provider -> {:ok, provider}
    end
  end

  defp detect do
    providers =
      Repo.all(
        from(p in Provider, where: p.enabled == true, order_by: [asc: p.priority, asc: p.name])
      )

    found =
      Enum.find(providers, &(&1.type == "gemini")) ||
        Enum.find(providers, &(&1.type == "ollama")) ||
        Enum.find(providers, &(&1.type in ["openai_compatible", "custom"]))

    if found, do: {:ok, found}, else: {:error, :no_embedding_provider}
  end
end
