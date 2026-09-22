defmodule AlexClaw.LLM.Window do
  @moduledoc """
  How much a provider can take in one call, so a prompt is never silently cut.

  Ollama answers a prompt longer than its context window by dropping the
  start of it — the instructions, usually — and replies anyway. A prompt is
  therefore measured against the provider's window before it is sent:

    * `context_window` in the provider's options, when set, is the window;
    * Ollama: `num_ctx` in its options, else Ollama's own default of 4096 —
      `/api/show` reports the model's maximum, not the window it runs with;
    * a local-tier OpenAI-compatible server: the context length LM Studio
      reports for the loaded model (`/api/v0/models`). Unknown for other
      servers — including OpenAI-compatible ones outside the local tier, which
      are not asked: they refuse an overlong prompt with an error rather than
      cutting it, and a call to them costs nothing on this host;
    * Gemini and Anthropic: their published windows.

  Token counts are estimated at three bytes per token, on the high side, so
  an estimate that fits leaves room rather than overflowing.
  """

  require Logger

  alias AlexClaw.LLM.Provider

  @ollama_default 4096
  @default_reserve 2048
  @published %{"gemini" => 1_000_000, "anthropic" => 200_000}

  @doc """
  The provider's context window in tokens, or nil when it cannot be known.
  A local-tier OpenAI-compatible server is asked for it (see `discoverable?/1`);
  `discover: false` skips even that.
  """
  @spec tokens(Provider.t(), keyword()) :: pos_integer() | nil
  def tokens(%Provider{} = provider, opts \\ []) do
    option(provider, "context_window") || by_type(provider, Keyword.get(opts, :discover, true))
  end

  @doc "Whether this provider's server is asked for its window."
  @spec discoverable?(Provider.t()) :: boolean()
  def discoverable?(%Provider{type: type, tier: "local"}),
    do: type in ["openai_compatible", "custom"]

  def discoverable?(%Provider{}), do: false

  @doc "Tokens kept free for the answer: num_predict or max_tokens, else #{@default_reserve}."
  @spec reserve(Provider.t()) :: pos_integer()
  def reserve(%Provider{} = provider) do
    option(provider, "num_predict") || option(provider, "max_tokens") || @default_reserve
  end

  @doc "A conservative token estimate for `text`."
  @spec estimate(String.t() | nil) :: non_neg_integer()
  def estimate(nil), do: 0
  def estimate(text) when is_binary(text), do: div(byte_size(text), 3) + 1

  @doc """
  Tokens left for a prompt once the system prompt and the answer's reserve are
  taken, or `:unlimited` when the window is unknown.
  """
  @spec budget(Provider.t(), String.t() | nil) :: non_neg_integer() | :unlimited
  def budget(provider, system) do
    case tokens(provider) do
      nil -> :unlimited
      window -> max(window - reserve(provider) - estimate(system), 0)
    end
  end

  @doc """
  Whether `prompt` and `system` fit the provider, with the figures when they
  do not. A local-tier server is asked for its window: one that is too small
  must refuse before the call, not after the model server has taken it on.
  Other servers' windows are checked when known without asking (see `tokens/2`).
  """
  @spec fits(Provider.t(), String.t(), String.t() | nil) :: :ok | {:error, map()}
  def fits(provider, prompt, system) do
    case tokens(provider) do
      nil ->
        :ok

      window ->
        room = window - reserve(provider) - estimate(system)
        fitting(estimate(prompt) <= room, provider, estimate(prompt) + estimate(system))
    end
  end

  defp fitting(true, _provider, _needed), do: :ok

  defp fitting(false, provider, needed) do
    {:error,
     %{
       provider: provider.name,
       window: tokens(provider),
       prompt_tokens: needed,
       reserve: reserve(provider)
     }}
  end

  defp option(%Provider{options: options}, key) when is_map(options) do
    # Options are stored as JSON, so keys are strings.
    case Map.get(options, key) do
      n when is_integer(n) and n > 0 -> n
      n when is_binary(n) -> positive_integer(Integer.parse(n))
      _ -> nil
    end
  end

  defp option(_provider, _key), do: nil

  defp positive_integer({n, ""}) when n > 0, do: n
  defp positive_integer(_), do: nil

  defp by_type(%Provider{type: "ollama"} = provider, _discover),
    do: option(provider, "num_ctx") || @ollama_default

  defp by_type(%Provider{type: type} = provider, discover)
       when type in ["openai_compatible", "custom"] do
    if discover and discoverable?(provider), do: reported(provider)
  end

  defp by_type(%Provider{type: type}, _discover), do: Map.get(@published, type)

  # LM Studio's own API; any other server answers 404 and the window is unknown.
  defp reported(%Provider{host: host, model: model}) when is_binary(host) and host != "" do
    url =
      String.trim_trailing(host, "/")
      |> String.replace_suffix("/v1", "")
      |> Kernel.<>("/api/v0/models")

    case Req.get(url, receive_timeout: 2_000, retry: false) do
      {:ok, %{status: 200, body: %{"data" => models}}} when is_list(models) ->
        loaded_context(models, model)

      _ ->
        nil
    end
  rescue
    e ->
      Logger.debug("Context window lookup failed: #{Exception.message(e)}")
      nil
  end

  defp reported(_provider), do: nil

  # The named model's loaded context; for "default", the loaded language model's.
  defp loaded_context(models, model) do
    models
    |> Enum.filter(&(&1["type"] in ["llm", "vlm"] and is_integer(&1["loaded_context_length"])))
    |> Enum.find(&(model in [nil, "", "default"] or &1["id"] == model))
    |> context_length()
  end

  defp context_length(nil), do: nil
  defp context_length(model), do: model["loaded_context_length"]
end
