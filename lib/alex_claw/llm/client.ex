defmodule AlexClaw.LLM.Client do
  @moduledoc """
  HTTP client for LLM provider APIs. Pure functions — no state, no CRUD.
  Handles completion and embedding calls for all supported provider types:
  Gemini, Anthropic, Ollama, and OpenAI-compatible (LM Studio, GROQ, custom).
  """
  require Logger

  alias AlexClaw.LLM.Provider

  # --- API Key Resolution ---

  @config_key_map %{
    "gemini" => "llm.gemini_api_key",
    "anthropic" => "llm.anthropic_api_key"
  }

  @doc "Resolve API key from provider record or config database."
  @spec resolve_api_key(Provider.t()) :: String.t()
  def resolve_api_key(%Provider{api_key: key}) when is_binary(key) and key != "", do: key

  def resolve_api_key(%Provider{type: type}), do: setting_api_key(type) || ""

  @doc "The API key a provider type reads from the settings, if it has one."
  @spec setting_api_key(String.t()) :: String.t() | nil
  def setting_api_key(type) do
    case Map.get(@config_key_map, type) do
      nil -> nil
      config_key -> AlexClaw.Config.get(config_key)
    end
  end

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
    api_key = resolve_api_key(p)

    if api_key == "",
      do: {:error, :api_key_not_set},
      else: call_embedding_gemini(api_key, text, model)
  end

  def call_embedding(%Provider{type: "ollama"} = p, text, model) do
    host = p.host || ""
    if host == "", do: {:error, :host_not_set}, else: call_embedding_ollama(host, text, model)
  end

  def call_embedding(%Provider{type: type} = p, text, model)
      when type in ["openai_compatible", "custom"] do
    host = p.host || ""

    if host == "",
      do: {:error, :host_not_set},
      else: call_embedding_openai(host, p.api_key, p.headers, text, model)
  end

  def call_embedding(%Provider{type: "anthropic"}, _text, _model) do
    {:error, :anthropic_no_embeddings}
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
        gemini_rate_limited(url, body, retries, resp_body, quota_exhausted?(resp_body))

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:gemini, status, resp_body}}

      {:error, reason} ->
        {:error, {:gemini, reason}}
    end
  end

  defp gemini_rate_limited(_url, _body, _retries, resp_body, true) do
    Logger.warning("Gemini daily quota exhausted, not retrying")
    {:error, {:gemini_quota_exhausted, resp_body}}
  end

  defp gemini_rate_limited(_url, _body, retries, resp_body, false) when retries <= 0 do
    {:error, {:gemini, 429, resp_body}}
  end

  defp gemini_rate_limited(url, body, retries, _resp_body, false) do
    wait = (4 - retries) * 5_000

    Logger.warning(
      "Gemini 429 rate limited, retrying in #{div(wait, 1000)}s (#{retries} retries left)"
    )

    Process.sleep(wait)
    do_gemini_request(url, body, retries - 1)
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
    url = "#{p.host}/v1/chat/completions"
    body = openai_body(p.model, p.options || %{}, chat_messages(prompt, system))
    headers = openai_headers(p.headers, p.api_key)

    url
    |> Req.post(json: body, headers: headers, receive_timeout: timeout)
    |> openai_response()
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

  defp call_embedding_gemini(api_key, text, model) do
    base = embedding_base_url() || "https://generativelanguage.googleapis.com"
    url = "#{base}/v1beta/models/#{model}:embedContent?key=#{api_key}"

    body = %{
      model: "models/#{model}",
      content: %{parts: [%{text: text}]},
      outputDimensionality: 768
    }

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

    case Req.post(url, json: body, headers: headers, receive_timeout: 600_000) do
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
