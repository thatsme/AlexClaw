defmodule AlexClaw.LLM do
  @moduledoc """
  Multi-model LLM router. All providers live in the database.
  Routes calls to the cheapest available provider that satisfies the
  requested reasoning tier. Tracks daily usage in ETS.
  """
  require Logger
  import Ecto.Query

  alias AlexClaw.LLM.Provider

  @type tier :: :light | :medium | :heavy | :local
  @type complete_opts :: [tier: tier(), system: String.t() | nil]
  @type llm_result :: {:ok, String.t()} | {:error, term()}

  # --- Provider CRUD ---

  @doc "List all LLM providers, ordered by tier and priority."
  @spec list_providers() :: [Provider.t()]
  def list_providers do
    AlexClaw.Repo.all(from(p in Provider, order_by: [p.tier, p.priority, p.name]))
  end

  @doc "Fetch a provider by ID. Returns `{:ok, provider}` or `{:error, :not_found}`."
  @spec get_provider(integer()) :: {:ok, Provider.t()} | {:error, :not_found}
  def get_provider(id) do
    case AlexClaw.Repo.get(Provider, id) do
      nil -> {:error, :not_found}
      provider -> {:ok, provider}
    end
  end

  @doc "Fetch a provider by ID. Raises if not found."
  @spec get_provider!(integer()) :: Provider.t()
  def get_provider!(id), do: AlexClaw.Repo.get!(Provider, id)

  @doc "Create a new LLM provider."
  @spec create_provider(map()) :: {:ok, Provider.t()} | {:error, Ecto.Changeset.t()}
  def create_provider(attrs) do
    %Provider{}
    |> Provider.changeset(attrs)
    |> AlexClaw.Repo.insert()
  end

  @doc "Update an existing provider."
  @spec update_provider(Provider.t(), map()) :: {:ok, Provider.t()} | {:error, Ecto.Changeset.t()}
  def update_provider(%Provider{} = provider, attrs) do
    provider
    |> Provider.changeset(attrs)
    |> AlexClaw.Repo.update()
  end

  @doc "Delete a provider."
  @spec delete_provider(Provider.t()) :: {:ok, Provider.t()} | {:error, Ecto.Changeset.t()}
  def delete_provider(%Provider{} = provider) do
    AlexClaw.Repo.delete(provider)
  end

  # --- Client API ---

  @doc """
  Complete a prompt using the cheapest available model for the given tier.

  Options:
    - `:tier` — reasoning tier (:light, :medium, :heavy, :local). Default :light
    - `:system` — system prompt
    - `:provider` — explicit provider name. Bypasses tier selection.
  """
  @spec complete(String.t(), complete_opts()) :: llm_result()
  def complete(prompt, opts \\ []) do
    system = Keyword.get(opts, :system, nil)
    provider_name = Keyword.get(opts, :provider, nil)

    case resolve_provider(provider_name, opts) do
      {:ok, provider} ->
        Logger.info("LLM call: #{provider.name} (#{provider.model})", provider: provider.name)
        result = call_provider(provider, prompt, system)
        if match?({:ok, _}, result), do: track_usage(provider.id)
        result

      {:error, reason} ->
        Logger.warning("No available model: #{inspect(reason)}")
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

  @doc "List all provider names for UI dropdowns (includes disabled providers)."
  @spec list_provider_choices() :: [map()]
  def list_provider_choices do
    providers =
      list_providers()
      |> Enum.map(fn p ->
        suffix = if p.enabled, do: "", else: " [disabled]"
        %{value: p.name, label: "#{p.name} (#{p.model})#{suffix}", group: p.tier}
      end)

    [%{value: "auto", label: "Auto (tier-based)", group: "auto"} | providers]
  end

  @doc """
  Generate a 768-dimension embedding for the given text.

  Resolves an embedding provider via config (`embedding.provider`) or auto-detects
  the first available Gemini → Ollama → OpenAI-compatible provider.

  Options:
    - `:provider` — explicit provider name (bypasses config/auto-detect)
  """
  @spec embed(String.t(), keyword()) :: {:ok, list(float())} | {:error, term()}
  def embed(text, opts \\ []) when is_binary(text) do
    case resolve_embedding_provider(opts) do
      {:ok, provider} ->
        model = AlexClaw.Config.get("embedding.model") || "text-embedding-004"
        result = call_embedding(provider, text, model)
        if match?({:ok, _}, result), do: track_usage(provider.id)
        result

      {:error, reason} ->
        Logger.warning("No embedding provider available: #{inspect(reason)}")
        {:error, reason}
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

  defp call_embedding(%Provider{type: "gemini"} = p, text, model) do
    api_key = p.api_key || ""

    if api_key == "",
      do: {:error, :api_key_not_set},
      else: call_embedding_gemini(api_key, text, model)
  end

  defp call_embedding(%Provider{type: "ollama"} = p, text, model) do
    host = p.host || ""
    if host == "", do: {:error, :host_not_set}, else: call_embedding_ollama(host, text, model)
  end

  defp call_embedding(%Provider{type: type} = p, text, model)
       when type in ["openai_compatible", "custom"] do
    host = p.host || ""

    if host == "",
      do: {:error, :host_not_set},
      else: call_embedding_openai(host, p.api_key, p.headers, text, model)
  end

  defp call_embedding(%Provider{type: "anthropic"}, _text, _model) do
    {:error, :anthropic_no_embeddings}
  end

  # --- Gemini Embeddings ---

  defp call_embedding_gemini(api_key, text, model) do
    base = embedding_base_url() || "https://generativelanguage.googleapis.com"
    url = "#{base}/v1beta/models/#{model}:embedContent?key=#{api_key}"
    body = %{model: "models/#{model}", content: %{parts: [%{text: text}]}}

    case Req.post(url, json: body) do
      {:ok, %{status: 200, body: %{"embedding" => %{"values" => values}}}} when is_list(values) ->
        {:ok, values}

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:gemini_embed, status, resp_body}}

      {:error, reason} ->
        {:error, {:gemini_embed, reason}}
    end
  end

  # --- Ollama Embeddings ---

  defp call_embedding_ollama(host, text, model) do
    url = "#{host}/api/embed"
    body = %{model: model, input: text}

    case Req.post(url, json: body, receive_timeout: 120_000) do
      {:ok, %{status: 200, body: %{"embeddings" => [vector | _]}}} when is_list(vector) ->
        {:ok, vector}

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:ollama_embed, status, resp_body}}

      {:error, reason} ->
        {:error, {:ollama_embed, reason}}
    end
  end

  # --- OpenAI-compatible Embeddings (LM Studio, etc.) ---

  defp call_embedding_openai(host, api_key, extra_headers, text, model) do
    url = "#{host}/v1/embeddings"

    headers =
      (extra_headers || %{})
      |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)

    headers =
      if api_key && api_key != "" do
        [{"authorization", "Bearer #{api_key}"} | headers]
      else
        headers
      end

    body = %{model: model, input: text}

    case Req.post(url, json: body, headers: headers, receive_timeout: 120_000) do
      {:ok, %{status: 200, body: %{"data" => [%{"embedding" => vector} | _]}}}
      when is_list(vector) ->
        {:ok, vector}

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:openai_embed, status, resp_body}}

      {:error, reason} ->
        {:error, {:openai_embed, reason}}
    end
  end

  # Allows overriding the Gemini base URL for testing via application config
  defp embedding_base_url, do: Application.get_env(:alex_claw, :embedding_base_url)

  # --- Model Selection ---

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
        # Fall back to local tier providers if no providers found for requested tier
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
  defp within_limit?(%Provider{id: id, daily_limit: limit}), do: get_usage(id) < limit

  # --- Usage Tracking (ETS) ---

  @table :alexclaw_llm_usage

  @doc "Create the ETS table for tracking daily LLM usage counts."
  @spec init_usage_table() :: :ets.table()
  def init_usage_table do
    :ets.new(@table, [:named_table, :public, :set])
  end

  defp track_usage(provider_id) when is_integer(provider_id) do
    key = {provider_id, Date.utc_today()}
    :ets.update_counter(@table, key, {2, 1}, {key, 0})
    AlexClaw.LLM.UsageTracker.persist(provider_id)
  end

  defp get_usage(provider_id) when is_integer(provider_id) do
    key = {provider_id, Date.utc_today()}

    case :ets.lookup(@table, key) do
      [{_, count}] -> count
      [] -> 0
    end
  end

  @doc "Get today's usage count for a provider by ID."
  @spec usage_today(integer()) :: non_neg_integer()
  def usage_today(provider_id), do: get_usage(provider_id)

  # --- Provider Calls ---

  defp call_provider(%Provider{type: "gemini"} = p, prompt, system) do
    api_key = p.api_key || ""

    if api_key == "",
      do: {:error, :api_key_not_set},
      else: call_gemini(p.model, api_key, prompt, system)
  end

  defp call_provider(%Provider{type: "anthropic"} = p, prompt, system) do
    api_key = p.api_key || ""

    if api_key == "",
      do: {:error, :api_key_not_set},
      else: call_anthropic(p.model, api_key, prompt, system)
  end

  defp call_provider(%Provider{type: "ollama"} = p, prompt, system) do
    host = p.host || ""
    if host == "", do: {:error, :host_not_set}, else: call_ollama(host, p.model, prompt, system)
  end

  defp call_provider(%Provider{type: type} = p, prompt, system)
       when type in ["openai_compatible", "custom"] do
    host = p.host || ""

    if host == "",
      do: {:error, :host_not_set},
      else: call_openai_compatible(host, p.model, p.api_key, p.headers, prompt, system)
  end

  # --- Gemini ---

  defp call_gemini(model, api_key, prompt, system) do
    url =
      "https://generativelanguage.googleapis.com/v1beta/models/#{model}:generateContent?key=#{api_key}"

    contents = [%{role: "user", parts: [%{text: prompt}]}]

    body =
      if system do
        %{contents: contents, systemInstruction: %{parts: [%{text: system}]}}
      else
        %{contents: contents}
      end

    do_gemini_request(url, body, _retries = 3)
  end

  defp do_gemini_request(url, body, retries) do
    case Req.post(url, json: body) do
      {:ok,
       %{
         status: 200,
         body: %{"candidates" => [%{"content" => %{"parts" => [%{"text" => text} | _]}} | _]}
       }} ->
        {:ok, text}

      {:ok, %{status: 429, body: resp_body}} ->
        if quota_exhausted?(resp_body) do
          Logger.warning("Gemini daily quota exhausted, not retrying")
          {:error, {:gemini_quota_exhausted, resp_body}}
        else
          if retries > 0 do
            wait = (4 - retries) * 5_000

            Logger.warning(
              "Gemini 429 rate limited, retrying in #{div(wait, 1000)}s (#{retries} retries left)"
            )

            Process.sleep(wait)
            do_gemini_request(url, body, retries - 1)
          else
            {:error, {:gemini, 429, resp_body}}
          end
        end

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:gemini, status, resp_body}}

      {:error, reason} ->
        {:error, {:gemini, reason}}
    end
  end

  defp quota_exhausted?(%{"error" => %{"status" => "RESOURCE_EXHAUSTED"} = error}) do
    details = Map.get(error, "details", [])
    has_retry_info = Enum.any?(details, &Map.has_key?(&1, "retryDelay"))
    not has_retry_info
  end

  defp quota_exhausted?(_), do: false

  # --- Anthropic ---

  defp call_anthropic(model, api_key, prompt, system) do
    url = "https://api.anthropic.com/v1/messages"

    headers = [
      {"x-api-key", api_key},
      {"anthropic-version", "2023-06-01"}
    ]

    body = %{model: model, max_tokens: 4096, messages: [%{role: "user", content: prompt}]}
    body = if system, do: Map.put(body, :system, system), else: body

    case Req.post(url, json: body, headers: headers) do
      {:ok, %{status: 200, body: %{"content" => [%{"text" => text} | _]}}} ->
        {:ok, text}

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:anthropic, status, resp_body}}

      {:error, reason} ->
        {:error, {:anthropic, reason}}
    end
  end

  # --- Ollama ---

  defp call_ollama(host, model, prompt, system) do
    url = "#{host}/api/generate"
    body = %{model: model, prompt: prompt, stream: false}
    body = if system, do: Map.put(body, :system, system), else: body

    case Req.post(url, json: body, receive_timeout: 120_000) do
      {:ok, %{status: 200, body: %{"response" => text}}} ->
        {:ok, text}

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:ollama, status, resp_body}}

      {:error, reason} ->
        {:error, {:ollama, reason}}
    end
  end

  # --- OpenAI Compatible (LM Studio, GROQ, custom) ---

  defp call_openai_compatible(host, model, api_key, extra_headers, prompt, system) do
    url = "#{host}/v1/chat/completions"

    messages =
      if system do
        [%{role: "system", content: system}, %{role: "user", content: prompt}]
      else
        [%{role: "user", content: prompt}]
      end

    headers =
      (extra_headers || %{})
      |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)

    headers =
      if api_key && api_key != "" do
        [{"authorization", "Bearer #{api_key}"} | headers]
      else
        headers
      end

    body = %{model: model, messages: messages, stream: false}

    case Req.post(url, json: body, headers: headers, receive_timeout: 120_000) do
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => text}} | _]}}} ->
        {:ok, text}

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:openai_compat, status, resp_body}}

      {:error, reason} ->
        {:error, {:openai_compat, reason}}
    end
  end
end
