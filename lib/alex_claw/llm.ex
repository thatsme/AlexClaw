defmodule AlexClaw.LLM do
  @moduledoc """
  Multi-model LLM router. Routes calls to the cheapest available provider
  that satisfies the requested reasoning tier. Tracks daily usage in ETS.
  All API keys and limits are read from AlexClaw.Config (runtime-editable).
  """
  require Logger
  import Ecto.Query

  alias AlexClaw.Config
  alias AlexClaw.LLM.Provider

  @type tier :: :light | :medium | :heavy | :local
  @type model :: :gemini_flash | :gemini_pro | :haiku | :sonnet | :opus | :ollama | :lm_studio
  @type complete_opts :: [tier: tier(), system: String.t() | nil]
  @type llm_result :: {:ok, String.t()} | {:error, term()}

  @tiers %{
    light: [:gemini_flash, :haiku, :lm_studio, :ollama],
    medium: [:gemini_pro, :sonnet, :lm_studio, :ollama],
    heavy: [:opus, :lm_studio, :ollama],
    local: [:lm_studio, :ollama]
  }

  # --- Provider CRUD ---

  @doc "List all custom DB-stored LLM providers, ordered by tier and name."
  @spec list_custom_providers() :: [Provider.t()]
  def list_custom_providers do
    AlexClaw.Repo.all(from p in Provider, order_by: [p.tier, p.name])
  end

  @doc "Fetch a custom provider by ID. Returns `{:ok, provider}` or `{:error, :not_found}`."
  @spec get_provider(integer()) :: {:ok, Provider.t()} | {:error, :not_found}
  def get_provider(id) do
    case AlexClaw.Repo.get(Provider, id) do
      nil -> {:error, :not_found}
      provider -> {:ok, provider}
    end
  end

  @doc "Fetch a custom provider by ID. Raises if not found."
  @spec get_provider!(integer()) :: Provider.t()
  def get_provider!(id), do: AlexClaw.Repo.get!(Provider, id)

  @doc "Create a new custom LLM provider."
  @spec create_provider(map()) :: {:ok, Provider.t()} | {:error, Ecto.Changeset.t()}
  def create_provider(attrs) do
    %Provider{}
    |> Provider.changeset(attrs)
    |> AlexClaw.Repo.insert()
  end

  @doc "Update an existing custom provider."
  @spec update_provider(Provider.t(), map()) :: {:ok, Provider.t()} | {:error, Ecto.Changeset.t()}
  def update_provider(%Provider{} = provider, attrs) do
    provider
    |> Provider.changeset(attrs)
    |> AlexClaw.Repo.update()
  end

  @doc "Delete a custom provider."
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
    - `:provider` — explicit provider name (e.g. "groq", "gemini_flash"). Bypasses tier selection.
  """
  @spec complete(String.t(), complete_opts()) :: llm_result()
  def complete(prompt, opts \\ []) do
    system = Keyword.get(opts, :system, nil)
    provider_name = Keyword.get(opts, :provider, nil)

    case resolve_provider(provider_name, opts) do
      {:builtin, model} ->
        Logger.info("LLM call: #{model}", provider: model)
        result = call_provider(model, prompt, system)
        track_usage(model)
        result

      {:custom, provider} ->
        Logger.info("LLM call: custom/#{provider.name}", provider: :custom)
        result = call_custom_provider(provider, prompt, system)
        track_usage({:custom, provider.id})
        result

      {:error, reason} ->
        Logger.warning("No available model: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp resolve_provider(nil, opts) do
    tier = Keyword.get(opts, :tier, :light)

    case select_model(tier) do
      {:ok, result} -> result
      {:error, _} = err -> err
    end
  end

  defp resolve_provider("auto", opts), do: resolve_provider(nil, opts)
  defp resolve_provider("", opts), do: resolve_provider(nil, opts)

  defp resolve_provider(name, _opts) when is_binary(name) do
    case builtin_by_name(name) do
      {:ok, model} -> {:builtin, model}
      :none -> find_custom_by_name(name)
    end
  end

  defp builtin_by_name("gemini_flash"), do: {:ok, :gemini_flash}
  defp builtin_by_name("gemini_pro"), do: {:ok, :gemini_pro}
  defp builtin_by_name("haiku"), do: {:ok, :haiku}
  defp builtin_by_name("sonnet"), do: {:ok, :sonnet}
  defp builtin_by_name("opus"), do: {:ok, :opus}
  defp builtin_by_name("ollama"), do: {:ok, :ollama}
  defp builtin_by_name("lm_studio"), do: {:ok, :lm_studio}
  defp builtin_by_name(_), do: :none

  defp find_custom_by_name(name) do
    case AlexClaw.Repo.one(from(p in Provider, where: p.name == ^name and p.enabled == true)) do
      nil -> {:error, {:unknown_provider, name}}
      provider -> {:custom, provider}
    end
  end

  @doc "List all available provider names (built-in + custom) for UI dropdowns."
  @spec list_provider_choices() :: [map()]
  def list_provider_choices do
    builtins =
      [
        %{value: "auto", label: "Auto (tier-based)", group: "auto"},
        %{value: "gemini_flash", label: "Gemini Flash", group: "builtin"},
        %{value: "gemini_pro", label: "Gemini Pro", group: "builtin"},
        %{value: "haiku", label: "Claude Haiku", group: "builtin"},
        %{value: "sonnet", label: "Claude Sonnet", group: "builtin"},
        %{value: "opus", label: "Claude Opus", group: "builtin"},
        %{value: "ollama", label: "Ollama", group: "builtin"},
        %{value: "lm_studio", label: "LM Studio", group: "builtin"}
      ]

    customs =
      list_custom_providers()
      |> Enum.map(fn p -> %{value: p.name, label: "#{p.name} (#{p.type})", group: "custom"} end)

    builtins ++ customs
  end

  @doc "Generate an embedding for the given text."
  @spec embed(String.t(), keyword()) :: {:ok, list(float()) | nil}
  def embed(_text, _opts \\ []) do
    {:ok, nil}
  end

  # --- Model Selection ---

  defp select_model(tier) do
    builtin_models = Map.get(@tiers, tier, [])

    case find_available_builtin(builtin_models) do
      {:ok, model} ->
        {:ok, {:builtin, model}}

      :none ->
        case find_custom_provider(tier) do
          {:ok, provider} -> {:ok, {:custom, provider}}
          :none -> {:error, :no_available_model}
        end
    end
  end

  defp find_available_builtin(models) do
    Enum.find_value(models, :none, fn model ->
      if available?(model), do: {:ok, model}
    end)
  end

  defp find_custom_provider(tier) do
    tier_str = Atom.to_string(tier)

    case AlexClaw.Repo.all(
           from(p in Provider,
             where: p.enabled == true and p.tier == ^tier_str,
             order_by: p.name
           )
         ) do
      [] ->
        :none

      providers ->
        Enum.find_value(providers, :none, fn provider ->
          if custom_within_limit?(provider), do: {:ok, provider}
        end)
    end
  end

  defp custom_within_limit?(%Provider{daily_limit: nil}), do: true

  defp custom_within_limit?(%Provider{id: id, daily_limit: limit}) do
    usage = get_usage({:custom, id})
    usage < limit
  end

  defp available?(model) do
    configured?(model) and within_limit?(model)
  end

  defp within_limit?(model) do
    case get_limit(model) do
      :unlimited -> true
      :paid -> true
      n when is_integer(n) -> get_usage(model) < n
    end
  end

  defp configured?(:gemini_flash), do: (Config.get("llm.gemini_api_key") || "") != ""
  defp configured?(:gemini_pro), do: (Config.get("llm.gemini_api_key") || "") != ""
  defp configured?(:haiku), do: (Config.get("llm.anthropic_api_key") || "") != ""
  defp configured?(:sonnet), do: (Config.get("llm.anthropic_api_key") || "") != ""
  defp configured?(:opus), do: (Config.get("llm.anthropic_api_key") || "") != ""
  defp configured?(:ollama), do: Config.get("llm.ollama_enabled") == true
  defp configured?(:lm_studio), do: Config.get("llm.lmstudio_enabled") == true

  defp get_limit(:gemini_flash), do: Config.get("llm.limit.gemini_flash") || 250
  defp get_limit(:gemini_pro), do: Config.get("llm.limit.gemini_pro") || 50
  defp get_limit(:haiku), do: Config.get("llm.limit.haiku") || 1_000
  defp get_limit(:sonnet), do: Config.get("llm.limit.sonnet") || 5
  defp get_limit(:opus), do: :paid
  defp get_limit(:ollama), do: :unlimited
  defp get_limit(:lm_studio), do: :unlimited

  # --- Usage Tracking (ETS) ---

  @table :alexclaw_llm_usage

  @doc "Create the ETS table for tracking daily LLM usage counts."
  @spec init_usage_table() :: :ets.table()
  def init_usage_table do
    :ets.new(@table, [:named_table, :public, :set])
  end

  defp track_usage(model) do
    key = {model, Date.utc_today()}
    :ets.update_counter(@table, key, {2, 1}, {key, 0})
    # Write-through to DB so counts survive restarts
    AlexClaw.LLM.UsageTracker.persist(model)
  end

  defp get_usage(model) do
    key = {model, Date.utc_today()}

    case :ets.lookup(@table, key) do
      [{_, count}] -> count
      [] -> 0
    end
  end

  # --- Provider Calls ---

  defp call_provider(:gemini_flash, prompt, system) do
    call_gemini("gemini-2.0-flash", prompt, system)
  end

  defp call_provider(:gemini_pro, prompt, system) do
    call_gemini("gemini-2.0-pro", prompt, system)
  end

  defp call_provider(:haiku, prompt, system) do
    call_anthropic("claude-haiku-4-5-20251001", prompt, system)
  end

  defp call_provider(:sonnet, prompt, system) do
    call_anthropic("claude-sonnet-4-6-20250514", prompt, system)
  end

  defp call_provider(:opus, prompt, system) do
    call_anthropic("claude-opus-4-6-20250514", prompt, system)
  end

  defp call_provider(:ollama, prompt, system) do
    call_ollama(prompt, system)
  end

  defp call_provider(:lm_studio, prompt, system) do
    call_lm_studio(prompt, system)
  end

  # --- Gemini ---

  defp call_gemini(model, prompt, system) do
    api_key = Config.get("llm.gemini_api_key") || ""

    if api_key == "" do
      {:error, :gemini_api_key_not_set}
    else
      url = "https://generativelanguage.googleapis.com/v1beta/models/#{model}:generateContent?key=#{api_key}"

      contents = [%{role: "user", parts: [%{text: prompt}]}]

      body =
        if system do
          %{contents: contents, systemInstruction: %{parts: [%{text: system}]}}
        else
          %{contents: contents}
        end

      do_gemini_request(url, body, _retries = 3)
    end
  end

  defp do_gemini_request(url, body, retries) do
    case Req.post(url, json: body) do
      {:ok, %{status: 200, body: %{"candidates" => [%{"content" => %{"parts" => [%{"text" => text} | _]}} | _]}}} ->
        {:ok, text}

      {:ok, %{status: 429, body: resp_body}} ->
        if quota_exhausted?(resp_body) do
          Logger.warning("Gemini daily quota exhausted, not retrying")
          {:error, {:gemini_quota_exhausted, resp_body}}
        else
          if retries > 0 do
            wait = (4 - retries) * 5_000
            Logger.warning("Gemini 429 rate limited, retrying in #{div(wait, 1000)}s (#{retries} retries left)")
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
    # Quota exhaustion: daily limit hit. Details often contain "limit": 0.
    # Rate limiting: per-minute burst, usually has retryDelay in details.
    details = Map.get(error, "details", [])

    has_retry_info =
      Enum.any?(details, fn detail ->
        Map.has_key?(detail, "retryDelay")
      end)

    # If there's a retryDelay hint, it's a rate limit (retryable).
    # If not, it's quota exhaustion (not retryable).
    not has_retry_info
  end

  defp quota_exhausted?(_), do: false

  # --- Anthropic ---

  defp call_anthropic(model, prompt, system) do
    api_key = Config.get("llm.anthropic_api_key") || ""

    if api_key == "" do
      {:error, :anthropic_api_key_not_set}
    else
      url = "https://api.anthropic.com/v1/messages"

      headers = [
        {"x-api-key", api_key},
        {"anthropic-version", "2023-06-01"}
      ]

      body = %{
        model: model,
        max_tokens: 4096,
        messages: [%{role: "user", content: prompt}]
      }

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
  end

  # --- Ollama ---

  defp call_ollama(prompt, system) do
    enabled = Config.get("llm.ollama_enabled")

    if enabled do
      host = Config.get("llm.ollama_host")
      model = Config.get("llm.ollama_model")
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
    else
      {:error, :ollama_disabled}
    end
  end

  # --- Custom DB Providers ---

  defp call_custom_provider(%Provider{type: "openai_compatible"} = p, prompt, system) do
    call_openai_compatible(p.host, p.model, p.api_key, p.headers, prompt, system)
  end

  defp call_custom_provider(%Provider{type: "ollama"} = p, prompt, system) do
    url = "#{p.host}/api/generate"
    body = %{model: p.model, prompt: prompt, stream: false}
    body = if system, do: Map.put(body, :system, system), else: body

    case Req.post(url, json: body, receive_timeout: 120_000) do
      {:ok, %{status: 200, body: %{"response" => text}}} -> {:ok, text}
      {:ok, %{status: status, body: resp_body}} -> {:error, {:custom_ollama, status, resp_body}}
      {:error, reason} -> {:error, {:custom_ollama, reason}}
    end
  end

  defp call_custom_provider(%Provider{type: "gemini"} = p, prompt, system) do
    call_gemini_with_key(p.model, p.api_key, prompt, system)
  end

  defp call_custom_provider(%Provider{type: "anthropic"} = p, prompt, system) do
    call_anthropic_with_key(p.model, p.api_key, prompt, system)
  end

  defp call_custom_provider(%Provider{type: "custom"} = p, prompt, system) do
    # Generic: POST JSON body to host, expect {"text": "..."} or OpenAI format
    call_openai_compatible(p.host, p.model, p.api_key, p.headers, prompt, system)
  end

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

  defp call_gemini_with_key(model, api_key, prompt, system) do
    url = "https://generativelanguage.googleapis.com/v1beta/models/#{model}:generateContent?key=#{api_key}"
    contents = [%{role: "user", parts: [%{text: prompt}]}]

    body =
      if system do
        %{contents: contents, systemInstruction: %{parts: [%{text: system}]}}
      else
        %{contents: contents}
      end

    case Req.post(url, json: body) do
      {:ok, %{status: 200, body: %{"candidates" => [%{"content" => %{"parts" => [%{"text" => text} | _]}} | _]}}} ->
        {:ok, text}

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:gemini_custom, status, resp_body}}

      {:error, reason} ->
        {:error, {:gemini_custom, reason}}
    end
  end

  defp call_anthropic_with_key(model, api_key, prompt, system) do
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
        {:error, {:anthropic_custom, status, resp_body}}

      {:error, reason} ->
        {:error, {:anthropic_custom, reason}}
    end
  end

  # --- LM Studio (OpenAI-compatible) ---

  defp call_lm_studio(prompt, system) do
    enabled = Config.get("llm.lmstudio_enabled")

    if enabled do
      host = Config.get("llm.lmstudio_host")
      model = Config.get("llm.lmstudio_model")
      url = "#{host}/v1/chat/completions"

      messages =
        if system do
          [
            %{role: "system", content: system},
            %{role: "user", content: prompt}
          ]
        else
          [%{role: "user", content: prompt}]
        end

      body = %{model: model, messages: messages, stream: false}

      case Req.post(url, json: body, receive_timeout: 120_000) do
        {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => text}} | _]}}} ->
          {:ok, text}

        {:ok, %{status: status, body: resp_body}} ->
          {:error, {:lm_studio, status, resp_body}}

        {:error, reason} ->
          {:error, {:lm_studio, reason}}
      end
    else
      {:error, :lm_studio_disabled}
    end
  end
end
