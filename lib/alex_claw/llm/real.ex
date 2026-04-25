defmodule AlexClaw.LLM.Real do
  @moduledoc false
  @behaviour AlexClaw.LLM.Behaviour

  require Logger
  import Ecto.Query

  alias AlexClaw.LLM
  alias AlexClaw.LLM.{Client, Provider}

  @impl true
  def complete(prompt, opts) do
    system = Keyword.get(opts, :system, nil)
    provider_name = Keyword.get(opts, :provider, nil)

    case resolve_provider(provider_name, opts) do
      {:ok, provider} ->
        Logger.info("LLM call: #{provider.name} (#{provider.model})", provider: provider.name)
        result = Client.call_provider(provider, prompt, system)
        if match?({:ok, _}, result), do: LLM.track_usage(provider.id)
        result

      {:error, reason} ->
        Logger.warning("No available model: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  def embed(text, opts) when is_binary(text) do
    case resolve_embedding_provider(opts) do
      {:ok, provider} ->
        model = AlexClaw.Config.get("embedding.model") || "text-embedding-004"
        result = Client.call_embedding(provider, text, model)
        if match?({:ok, _}, result), do: LLM.track_usage(provider.id)
        result

      {:error, reason} ->
        Logger.warning("No embedding provider available: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp resolve_provider(nil, opts), do: select_model(Keyword.get(opts, :tier, :light))
  defp resolve_provider("auto", opts), do: resolve_provider(nil, opts)
  defp resolve_provider("", opts), do: resolve_provider(nil, opts)

  defp resolve_provider(name, _opts) when is_binary(name) do
    case AlexClaw.Repo.one(from(p in Provider, where: p.name == ^name and p.enabled == true)) do
      nil -> {:error, {:unknown_provider, name}}
      provider -> {:ok, provider}
    end
  end

  defp resolve_embedding_provider(opts) do
    case Keyword.get(opts, :provider) do
      name when is_binary(name) and name != "" ->
        resolve_provider(name, [])

      _ ->
        configured = AlexClaw.Config.get("embedding.provider")

        if configured && configured != "" do
          resolve_provider(configured, [])
        else
          auto_detect_embedding_provider()
        end
    end
  end

  defp auto_detect_embedding_provider do
    query =
      from(p in Provider,
        where: p.enabled == true,
        order_by: [asc: p.priority, asc: p.name]
      )

    providers = AlexClaw.Repo.all(query)

    result =
      Enum.find(providers, &(&1.type == "gemini")) ||
        Enum.find(providers, &(&1.type == "ollama")) ||
        Enum.find(providers, &(&1.type in ["openai_compatible", "custom"]))

    case result do
      nil -> {:error, :no_embedding_provider}
      provider -> {:ok, provider}
    end
  end

  defp select_model(tier) do
    tier_str = Atom.to_string(tier)

    providers =
      AlexClaw.Repo.all(
        from(p in Provider,
          where: p.enabled == true and p.tier == ^tier_str,
          order_by: [asc: p.priority, asc: p.name]
        )
      )

    case providers do
      [] ->
        if tier != :local do
          select_model(:local)
        else
          {:error, :no_available_model}
        end

      providers ->
        case Enum.find(providers, &within_limit?/1) do
          nil -> {:error, :all_providers_at_limit}
          provider -> {:ok, provider}
        end
    end
  end

  defp within_limit?(%Provider{daily_limit: nil}), do: true
  defp within_limit?(%Provider{id: id, daily_limit: limit}), do: LLM.usage_today(id) < limit
end
