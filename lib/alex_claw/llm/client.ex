defmodule AlexClaw.LLM.Client do
  @moduledoc """
  HTTP client for LLM provider APIs. Pure functions — no state, no CRUD.
  Handles completion and embedding calls for all supported provider types:
  Gemini, Anthropic, Ollama, and OpenAI-compatible (LM Studio, GROQ, custom).
  """
  require Logger

  alias AlexClaw.Config
  alias AlexClaw.LLM.{Provider, ProviderSecrets}
  alias AlexClaw.Net.Credentials

  # A provider call carries its key (and any custom headers): a redirect to
  # another host is refused rather than followed with them (S8 H7).
  defp post_credentialed(opts) do
    opts
    |> Keyword.put(:method, :post)
    |> Req.new()
    |> Credentials.guard_redirects(credentialed: true)
    |> Req.request()
  end

  # --- API Key Resolution ---

  @config_key_map %{
    "gemini" => "llm.gemini_api_key",
    "anthropic" => "llm.anthropic_api_key"
  }

  @gemini_base "https://generativelanguage.googleapis.com"
  @anthropic_url "https://api.anthropic.com/v1/messages"

  @doc """
  The API key for a provider's completion calls: its own, or else its type's
  secret setting, resolved for the host the call goes to.
  """
  @spec resolve_api_key(Provider.t()) :: String.t()
  def resolve_api_key(%Provider{type: type} = p), do: resolve_api_key(p, completion_host(type))

  defp resolve_api_key(%Provider{type: type} = p, destination),
    do: own_key(p) || setting_api_key(type, destination) || ""

  # The provider's own key, from OpenBao for its host. A failure to resolve it
  # is logged by name and falls back as a missing key would.
  defp own_key(%Provider{} = p), do: own_key(ProviderSecrets.resolved(p), p)

  defp own_key({:ok, key, _headers}, _p), do: key

  defp own_key({:error, reason}, p) do
    Logger.warning(
      "LLM provider #{p.name}: its API key could not be resolved (#{inspect(reason)})"
    )

    nil
  end

  @doc """
  The API key a provider type reads from its secret setting, if it has one,
  resolved for the type's completion host (the use is audited).
  """
  @spec setting_api_key(String.t()) :: String.t() | nil
  def setting_api_key(type), do: setting_api_key(type, completion_host(type))

  defp setting_api_key(type, destination) do
    case Map.get(@config_key_map, type) do
      nil -> nil
      config_key -> Config.secret_value(config_key, for: destination)
    end
  end

  defp completion_host("gemini"), do: host_binding(@gemini_base)
  defp completion_host("anthropic"), do: host_binding(@anthropic_url)
  defp completion_host(_type), do: nil

  defp host_binding(url), do: "host:" <> URI.parse(url).host

  # --- Provider Completion Calls ---

  @doc "Dispatch a completion call to the correct provider API."
  @spec call_provider(Provider.t(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def call_provider(%Provider{type: "gemini"} = p, prompt, system) do
    api_key = resolve_api_key(p)

    if api_key == "",
      do: {:error, :api_key_not_set},
      else: call_gemini(p.model, api_key, prompt, system)
  end

  def call_provider(%Provider{type: "anthropic"} = p, prompt, system) do
    api_key = resolve_api_key(p)

    if api_key == "",
      do: {:error, :api_key_not_set},
      else: call_anthropic(p.model, api_key, prompt, system)
  end

  def call_provider(%Provider{type: "ollama"} = p, prompt, system) do
    host = p.host || ""

    if host == "",
      do: {:error, :host_not_set},
      else: call_ollama(host, p.model, p.options || %{}, prompt, system, receive_timeout(p))
  end

  def call_provider(%Provider{type: type} = p, prompt, system)
      when type in ["openai_compatible", "custom"] do
    host = p.host || ""

    if host == "",
      do: {:error, :host_not_set},
      else: call_openai_compatible(p, prompt, system, receive_timeout(p))
  end

  @remote_timeout_ms 600_000
  @default_local_timeout_seconds 240

  # A local model shares the host with everything else: a call it cannot finish
  # in `llm.local_timeout_seconds` is abandoned rather than left to hold the GPU.
  defp receive_timeout(%Provider{tier: "local"}),
    do: local_timeout_seconds(AlexClaw.Config.get("llm.local_timeout_seconds")) * 1000

  defp receive_timeout(_provider), do: @remote_timeout_ms

  defp local_timeout_seconds(n) when is_integer(n) and n > 0, do: n
  defp local_timeout_seconds(_), do: @default_local_timeout_seconds

  # --- Provider Embedding Calls ---

  @doc "Dispatch an embedding call to the correct provider API."
  @spec call_embedding(Provider.t(), String.t(), String.t()) ::
          {:ok, list(float())} | {:error, term()}
  def call_embedding(%Provider{type: "gemini"} = p, text, model) do
    base = embedding_base_url() || @gemini_base
    api_key = resolve_api_key(p, host_binding(base))

    if api_key == "",
      do: {:error, :api_key_not_set},
      else: call_embedding_gemini(base, api_key, text, model)
  end

  def call_embedding(%Provider{type: "ollama"} = p, text, model) do
    host = p.host || ""
    if host == "", do: {:error, :host_not_set}, else: call_embedding_ollama(host, text, model)
  end

  def call_embedding(%Provider{type: type} = p, text, model)
      when type in ["openai_compatible", "custom"] do
    embedded_openai(p.host || "", p, text, model)
  end

  def call_embedding(%Provider{type: "anthropic"}, _text, _model) do
    {:error, :anthropic_no_embeddings}
  end

  defp embedded_openai("", _p, _text, _model), do: {:error, :host_not_set}

  defp embedded_openai(host, p, text, model) do
    with {:ok, api_key, headers} <- ProviderSecrets.resolved(p),
         do: call_embedding_openai(host, api_key, headers, text, model)
  end

  # --- Gemini ---

  # The key goes in the x-goog-api-key header, never in the URL, where it would
  # land in any log that records request lines.
  defp call_gemini(model, api_key, prompt, system) do
    url = "#{@gemini_base}/v1beta/models/#{model}:generateContent"

    contents = [%{role: "user", parts: [%{text: prompt}]}]

    body =
      if system do
        %{contents: contents, systemInstruction: %{parts: [%{text: system}]}}
      else
        %{contents: contents}
      end

    do_gemini_request([url: url, headers: [{"x-goog-api-key", api_key}]], body, _retries = 3)
  end

  defp do_gemini_request(request, body, retries) do
    case post_credentialed([json: body] ++ request) do
      {:ok,
       %{
         status: 200,
         body: %{"candidates" => [%{"content" => %{"parts" => [%{"text" => text} | _]}} | _]}
       }} ->
        {:ok, text}

      {:ok, %{status: 429, body: resp_body}} ->
        gemini_rate_limited(request, body, retries, resp_body, quota_exhausted?(resp_body))

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:gemini, status, resp_body}}

      {:error, reason} ->
        {:error, {:gemini, reason}}
    end
  end

  defp gemini_rate_limited(_request, _body, _retries, resp_body, true) do
    Logger.warning("Gemini daily quota exhausted, not retrying")
    {:error, {:gemini_quota_exhausted, resp_body}}
  end

  defp gemini_rate_limited(_request, _body, retries, resp_body, false) when retries <= 0 do
    {:error, {:gemini, 429, resp_body}}
  end

  defp gemini_rate_limited(request, body, retries, _resp_body, false) do
    wait = (4 - retries) * 5_000

    Logger.warning(
      "Gemini 429 rate limited, retrying in #{div(wait, 1000)}s (#{retries} retries left)"
    )

    Process.sleep(wait)
    do_gemini_request(request, body, retries - 1)
  end

  defp quota_exhausted?(%{"error" => %{"status" => "RESOURCE_EXHAUSTED"} = error}) do
    details = Map.get(error, "details", [])
    has_retry_info = Enum.any?(details, &Map.has_key?(&1, "retryDelay"))
    not has_retry_info
  end

  defp quota_exhausted?(_), do: false

  # --- Anthropic ---

  defp call_anthropic(model, api_key, prompt, system) do
    url = @anthropic_url

    headers = [
      {"x-api-key", api_key},
      {"anthropic-version", "2023-06-01"}
    ]

    body = %{model: model, max_tokens: 4096, messages: [%{role: "user", content: prompt}]}
    body = if system, do: Map.put(body, :system, system), else: body

    case post_credentialed(url: url, json: body, headers: headers) do
      {:ok, %{status: 200, body: %{"content" => [%{"text" => text} | _]}}} ->
        {:ok, text}

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:anthropic, status, resp_body}}

      {:error, reason} ->
        {:error, {:anthropic, reason}}
    end
  end

  # --- Ollama ---

  defp call_ollama(host, model, options, prompt, system, timeout) do
    url = "#{host}/api/chat"

    messages =
      if system do
        [%{role: "system", content: system}, %{role: "user", content: prompt}]
      else
        [%{role: "user", content: prompt}]
      end

    {thinking, ollama_opts} =
      options
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.pop("thinking")

    body = %{model: model, messages: messages, stream: false}
    body = if ollama_opts == %{}, do: body, else: Map.put(body, :options, ollama_opts)
    # Ollama takes thinking as a top-level field, not a model option.
    body = if thinking == false, do: Map.put(body, :think, false), else: body

    case Req.post(url, json: body, receive_timeout: timeout) do
      {:ok, %{status: 200, body: %{"message" => %{"content" => text}}}} ->
        {:ok, text}

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:ollama, status, resp_body}}

      {:error, reason} ->
        {:error, {:ollama, reason}}
    end
  end

  # --- OpenAI Compatible (LM Studio, GROQ, custom) ---

  defp call_openai_compatible(%Provider{} = p, prompt, system, timeout) do
    with {:ok, api_key, headers} <- ProviderSecrets.resolved(p) do
      url = "#{p.host}/v1/chat/completions"
      body = openai_body(p.model, p.options || %{}, chat_messages(prompt, system))

      [url: url, json: body, headers: openai_headers(headers, api_key), receive_timeout: timeout]
      |> post_credentialed()
      |> openai_response()
    end
  end

  defp chat_messages(prompt, nil), do: [%{role: "user", content: prompt}]

  defp chat_messages(prompt, system),
    do: [%{role: "system", content: system}, %{role: "user", content: prompt}]

  defp openai_headers(extra_headers, api_key) do
    headers = Enum.map(extra_headers || %{}, fn {k, v} -> {to_string(k), to_string(v)} end)
    authorization_header(headers, api_key)
  end

  defp authorization_header(headers, api_key) when api_key in [nil, ""], do: headers

  defp authorization_header(headers, api_key),
    do: [{"authorization", "Bearer #{api_key}"} | headers]

  # OpenAI-compatible APIs use top-level fields, not nested options
  @openai_keys %{
    "temperature" => :temperature,
    "top_p" => :top_p,
    "max_tokens" => :max_tokens,
    "num_predict" => :max_tokens
  }

  defp openai_body(model, options, messages) do
    openai_opts =
      Enum.reduce(options, %{}, fn {k, v}, acc -> put_openai_opt(acc, to_string(k), v) end)

    %{model: model, messages: messages, stream: false}
    |> Map.merge(openai_opts)
    |> put_thinking(Map.get(options, "thinking", Map.get(options, :thinking)))
  end

  defp put_openai_opt(acc, key, value) do
    case Map.get(@openai_keys, key) do
      nil -> acc
      field -> Map.put_new(acc, field, value)
    end
  end

  # Disable thinking mode for models that support it (e.g. Qwen3)
  defp put_thinking(body, false),
    do: Map.put(body, :chat_template_kwargs, %{enable_thinking: false})

  defp put_thinking(body, _thinking), do: body

  defp openai_response({:ok, %{status: 200, body: %{"choices" => [%{"message" => msg} | _]}}}),
    do: openai_text(msg["content"] || "", msg["reasoning_content"] || "")

  defp openai_response({:ok, %{status: status, body: resp_body}}),
    do: {:error, {:openai_compat, status, resp_body}}

  defp openai_response({:error, reason}), do: {:error, {:openai_compat, reason}}

  defp openai_text("", ""), do: {:error, {:openai_compat, :empty_response}}
  defp openai_text("", reasoning), do: {:ok, reasoning}
  defp openai_text(text, _reasoning), do: {:ok, text}

  # --- Gemini Embeddings ---

  defp call_embedding_gemini(base, api_key, text, model) do
    url = "#{base}/v1beta/models/#{model}:embedContent"

    body = %{
      model: "models/#{model}",
      content: %{parts: [%{text: text}]},
      outputDimensionality: 768
    }

    case post_credentialed(url: url, json: body, headers: [{"x-goog-api-key", api_key}]) do
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

    case Req.post(url, json: body, receive_timeout: 600_000) do
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

    headers = Enum.map(extra_headers || %{}, fn {k, v} -> {to_string(k), to_string(v)} end)

    headers =
      if api_key && api_key != "" do
        [{"authorization", "Bearer #{api_key}"} | headers]
      else
        headers
      end

    body = %{model: model, input: text}

    case post_credentialed(url: url, json: body, headers: headers, receive_timeout: 600_000) do
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
end
