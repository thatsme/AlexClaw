defmodule AlexClaw.LLM.Real do
  @moduledoc false
  @behaviour AlexClaw.LLM.Behaviour

  require Logger
  import Ecto.Query

  alias AlexClaw.LLM
  alias AlexClaw.LLM.{Client, Embedding, Provider}

  @impl true
  def complete(prompt, opts) do
    system = Keyword.get(opts, :system, nil)

    case candidates(Keyword.get(opts, :provider, nil), opts) do
      {:ok, providers} ->
        first_answer(providers, prompt, system)

      {:error, reason} ->
        Logger.warning("No available model: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # A provider that fails — down, no model loaded, an error status — hands the
  # call to the next candidate. The last failure is what the caller sees.
  defp first_answer(providers, prompt, system) do
    Enum.reduce_while(providers, {:error, :no_available_model}, fn provider, _last ->
      provider |> call(prompt, system) |> answered(provider)
    end)
  end

  defp call(provider, prompt, system) do
    Logger.info("LLM call: #{provider.name} (#{provider.model})", provider: provider.name)
    Client.call_provider(provider, prompt, system)
  end

  defp answered({:ok, _} = result, provider) do
    LLM.track_usage(provider.id)
    {:halt, result}
  end

  defp answered({:error, reason} = error, provider) do
    Logger.warning(
      "LLM call to #{provider.name} failed, trying the next provider: #{inspect(reason)}",
      provider: provider.name
    )

    {:cont, error}
  end

  @impl true
  def embed(text, opts) when is_binary(text) do
    with {:ok, provider} <- Embedding.provider(opts),
         {:ok, model} <- embedding_model(provider) do
      result = Client.call_embedding(provider, text, model)
      if match?({:ok, _}, result), do: LLM.track_usage(provider.id)
      result
    else
      {:error, reason} ->
        Logger.warning("No embedding available: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Anthropic has no embedding API; the client says so in its own words.
  defp embedding_model(%Provider{type: "anthropic"}), do: {:ok, nil}

  defp embedding_model(provider) do
    case Embedding.model_for(provider) do
      nil -> {:error, {:no_embedding_model, provider.name}}
      model -> {:ok, model}
    end
  end

  # A named provider is the only candidate: asking for it by name means that one.
  defp candidates(name, opts) when name in [nil, "", "auto"],
    do: select_models(Keyword.get(opts, :tier, :light))

  defp candidates(name, _opts) when is_binary(name) do
    case AlexClaw.Repo.one(from(p in Provider, where: p.name == ^name and p.enabled == true)) do
      nil -> {:error, {:unknown_provider, name}}
      provider -> {:ok, [provider]}
    end
  end

  # The tier's providers by priority, then the local tier's: a call that finds
  # no answer in its tier falls back to local models. At limit is skipped.
  defp select_models(tier) do
    tier_providers = enabled_in(Atom.to_string(tier))
    local = if tier == :local, do: [], else: enabled_in("local")

    case Enum.filter(tier_providers ++ local, &within_limit?/1) do
      [] when tier_providers == [] and local == [] -> {:error, :no_available_model}
      [] -> {:error, :all_providers_at_limit}
      providers -> {:ok, providers}
    end
  end

  defp enabled_in(tier) do
    AlexClaw.Repo.all(
      from(p in Provider,
        where: p.enabled == true and p.tier == ^tier,
        order_by: [asc: p.priority, asc: p.name]
      )
    )
  end

  defp within_limit?(%Provider{daily_limit: nil}), do: true
  defp within_limit?(%Provider{id: id, daily_limit: limit}), do: LLM.usage_today(id) < limit
end
