defmodule AlexClaw.Skills.WebBrowse do
  @moduledoc """
  Web browsing skill. Fetches a URL, extracts readable text content,
  and optionally answers a question about it via LLM.
  """
  @behaviour AlexClaw.Skill
  @impl true
  def external, do: true
  @impl true
  @spec description() :: String.t()
  def description, do: "Fetches a URL, extracts readable text, optionally answers questions via LLM"

  @impl true
  @spec routes() :: [atom()]
  def routes, do: [:on_success, :on_not_found, :on_timeout, :on_error]
  require Logger
  import AlexClaw.Skills.Helpers, only: [sanitize_utf8: 1, strip_noise: 1]

  alias AlexClaw.{Gateway, Identity, LLM, Memory}

  @max_content_length 8_000

  @doc "Workflow-compatible entry point. Uses config url/question or args[:input] as URL."
  @impl true
  @spec run(map()) :: {:ok, String.t() | nil, atom()} | {:error, any()}
  def run(args) do
    config = args[:config] || %{}
    url = config["url"] || to_string(args[:input] || "")
    question = config["question"]

    llm_opts =
      case args[:llm_provider] do
        nil -> []
        "" -> []
        "auto" -> []
        provider -> [provider: provider]
      end

    llm_opts =
      case args[:llm_tier] do
        nil -> llm_opts
        tier when is_atom(tier) -> [{:tier, tier} | llm_opts]
        tier when is_binary(tier) -> [{:tier, String.to_existing_atom(tier)} | llm_opts]
      end

    if url == "" do
      {:error, :no_url}
    else
      case fetch_and_extract(url) do
        {:ok, raw_content} ->
          content = AlexClaw.ContentSanitizer.sanitize(raw_content, skill: "web_browse")

          if question && question != "" do
            run_qa(url, content, question, llm_opts)
          else
            run_summarize(url, content, llm_opts)
          end

        {:error, {:http, 404}} ->
          {:ok, nil, :on_not_found}

        {:error, %Req.TransportError{reason: :timeout}} ->
          {:ok, nil, :on_timeout}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp run_summarize(url, content, llm_opts) do
    system = Identity.system_prompt(%{skill: :research})

    prompt = """
    Summarize the following web page content concisely. Focus on key facts and main points.

    URL: #{url}

    Content:
    #{content}
    """

    default_tier = resolve_tier()
    case LLM.complete(prompt, [{:tier, default_tier}, {:system, system}] ++ llm_opts) do
      {:ok, response} ->
        Memory.store(:web_page, response, source: url, metadata: %{type: "summary"})
        {:ok, response, :on_success}

      {:error, reason} ->
        {:error, {:summarize_failed, reason}}
    end
  end

  defp run_qa(url, content, question, llm_opts) do
    system = Identity.system_prompt(%{skill: :research})

    prompt = """
    Answer the following question based on the web page content below.
    Be concise and precise. If the answer is not in the content, say so.

    Question: #{question}

    URL: #{url}
    Content:
    #{content}
    """

    default_tier = resolve_tier()
    case LLM.complete(prompt, [{:tier, default_tier}, {:system, system}] ++ llm_opts) do
      {:ok, response} ->
        Memory.store(:web_page, response, source: url, metadata: %{type: "qa", question: question})
        {:ok, response, :on_success}

      {:error, reason} ->
        {:error, {:qa_failed, reason}}
    end
  end

  @spec handle(String.t(), String.t() | nil, keyword()) :: :ok
  def handle(url, question \\ nil, opts \\ []) do
    Logger.info("WebBrowse: #{url}#{if question, do: " — #{question}", else: ""}", skill: :web)
    gateway_opts = Keyword.take(opts, [:gateway, :chat_id])

    tier = Keyword.get(opts, :tier, resolve_tier())
    provider = Keyword.get(opts, :provider, resolve_provider())

    config = %{"url" => url}
    config = if question, do: Map.put(config, "question", question), else: config

    llm_provider = if provider && provider != "auto", do: provider, else: nil

    case run(%{config: config, llm_provider: llm_provider, llm_tier: tier}) do
      {:ok, response, _branch} -> Gateway.send_message(response, gateway_opts)
      {:error, reason} ->
        Logger.warning("WebBrowse failed: #{inspect(reason)}", skill: :web)
        Gateway.send_message("Failed: #{inspect(reason)}", gateway_opts)
    end
  end

  defp resolve_tier, do: String.to_existing_atom(AlexClaw.Config.get("skill.web_browse.tier") || "light")
  defp resolve_provider do
    case AlexClaw.Config.get("skill.web_browse.provider") do
      p when p in [nil, "", "auto"] -> nil
      p -> p
    end
  end

  defp fetch_and_extract(url) do
    headers = [
      {"user-agent", "Mozilla/5.0 (compatible; AlexClaw/1.0)"},
      {"accept", "text/html,application/xhtml+xml"}
    ]

    case Req.get(url, headers: headers, receive_timeout: 15_000, redirect: true, max_redirects: 5) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, extract_text(body)}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_text(html) do
    html
    |> sanitize_utf8()
    |> Floki.parse_document!()
    |> strip_noise()
    |> Floki.text(sep: "\n")
    |> clean_text()
    |> String.slice(0, @max_content_length)
  end


  defp clean_text(text) do
    text
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.replace(~r/[ \t]+/, " ")
    |> String.trim()
  end

end
