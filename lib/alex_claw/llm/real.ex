defmodule AlexClaw.LLM.Real do
  @moduledoc false
  @behaviour AlexClaw.LLM.Behaviour

  require Logger
  import Ecto.Query

  alias AlexClaw.LLM
  alias AlexClaw.LLM.{Client, Embedding, LocalLock, Provider, Window}

  @impl true
  def complete(prompt, opts), do: complete_with({:prompt, prompt}, opts)

  @doc """
  Complete a prompt built for each candidate provider's window: `build` gets
  the tokens the prompt may use (`:unlimited` when the window is unknown) and
  answers `{:ok, prompt}`, or `{:error, {:does_not_fit, tokens}}` when even its
  mandatory part is larger. A prompt is never sent to a provider it does not
  fit, nor handed to the next one: the error names the provider's window.
  """
  @spec complete_fitted(
          (non_neg_integer() | :unlimited -> {:ok, String.t()} | {:error, term()}),
          keyword()
        ) :: {:ok, String.t()} | {:error, term()}
  @impl true
  def complete_fitted(build, opts), do: complete_with({:build, build}, opts)

  defp complete_with(source, opts) do
    system = Keyword.get(opts, :system, nil)

    case candidates(Keyword.get(opts, :provider, nil), opts) do
      {:ok, providers} ->
        providers |> Enum.map(&with_call_options(&1, opts)) |> first_answer(source, system)

      {:error, reason} ->
        Logger.warning("No available model: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # `thinking: false` in the call's options overrides the provider's setting:
  # a caller that needs a strict format (a code block, one number per line) asks
  # a thinking model to answer directly rather than reason in prose first.
  defp with_call_options(provider, opts) do
    case Keyword.fetch(opts, :thinking) do
      {:ok, thinking} ->
        %{provider | options: Map.put(provider.options || %{}, "thinking", thinking)}

      :error ->
        provider
    end
  end

  # Only a transient failure — a timeout, a refused connection, a 5xx — hands
  # the call to the next candidate: another server may not share it. Anything
  # else is the answer. A 4xx is about the request and would be refused again
  # or, worse, taken on by a larger model; a prompt too large for the provider
  # is refused before it is sent, for the same reason.
  #
  # And a local provider is never the fallback for another local one, whatever
  # the failure: the second server loads its own model beside the first, which
  # is what took the host down. A cloud provider after a local failure is fine
  # — it costs this machine nothing.
  defp first_answer(providers, source, system) do
    providers
    |> Enum.reduce_while({:no_available_model, false}, &step(&1, source, system, &2))
    |> answer()
  end

  defp answer({:ok, _text} = result), do: result
  defp answer({reason, _local_failed}), do: {:error, reason}

  defp step(%Provider{tier: "local"} = provider, _source, _system, {reason, true}) do
    Logger.warning(
      "#{provider.name} not tried: a local provider already failed this call",
      provider: provider.name
    )

    {:cont, {reason, true}}
  end

  defp step(provider, source, system, {_reason, local_failed}) do
    attempt(provider, source, system, local_failed)
  end

  defp attempt(provider, source, system, local_failed) do
    with {:ok, prompt} <- prompt_for(source, provider, system),
         :ok <- Window.fits(provider, prompt, system) do
      provider |> call(prompt, system) |> answered(provider, local_failed)
    else
      {:error, {:does_not_fit, tokens}} ->
        too_large(provider, tokens + Window.estimate(system), local_failed)

      {:error, %{prompt_tokens: needed}} ->
        too_large(provider, needed, local_failed)
    end
  end

  # A built prompt learns the provider's budget first; a given one is only checked.
  defp prompt_for({:prompt, prompt}, _provider, _system), do: {:ok, prompt}
  defp prompt_for({:build, build}, provider, system), do: build.(Window.budget(provider, system))

  defp too_large(provider, needed, local_failed) do
    window = Window.tokens(provider)

    Logger.warning(
      "Prompt of ~#{needed} tokens does not fit #{provider.name} (window #{window}, " <>
        "#{Window.reserve(provider)} kept for the answer) — refused before the call",
      provider: provider.name
    )

    entry = %{provider: provider.name, window: window, prompt_tokens: needed}
    {:halt, {{:prompt_too_large, [entry]}, local_failed}}
  end

  # One local call at a time: several at once only queue inside the model
  # server, each holding its own context in the host's memory.
  defp call(%Provider{tier: "local"} = provider, prompt, system),
    do: LocalLock.run(fn -> dispatch(provider, prompt, system) end)

  defp call(provider, prompt, system), do: dispatch(provider, prompt, system)

  defp dispatch(provider, prompt, system) do
    Logger.info("LLM call: #{provider.name} (#{provider.model})", provider: provider.name)
    Client.call_provider(provider, prompt, system)
  end

  defp answered({:ok, _} = result, provider, _local_failed) do
    LLM.track_usage(provider.id)
    {:halt, result}
  end

  defp answered({:error, reason}, provider, local_failed) do
    failed_local = local_failed or provider.tier == "local"
    handed_on(transient?(reason), reason, provider, failed_local)
  end

  defp handed_on(true, reason, provider, local_failed) do
    Logger.warning(
      "LLM call to #{provider.name} failed, trying the next provider: #{inspect(reason)}",
      provider: provider.name
    )

    {:cont, {reason, local_failed}}
  end

  defp handed_on(false, reason, _provider, local_failed), do: {:halt, {reason, local_failed}}

  @transient_transport [:timeout, :econnrefused]

  defp transient?({_source, status, _body}) when is_integer(status) and status >= 500, do: true

  defp transient?({_source, %Req.TransportError{reason: reason}})
       when reason in @transient_transport,
       do: true

  defp transient?(_reason), do: false

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
