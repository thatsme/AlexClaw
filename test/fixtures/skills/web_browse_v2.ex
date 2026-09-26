defmodule AlexClaw.Skills.Dynamic.WebBrowseV2 do
  @moduledoc """
  Dynamic web browsing skill. Fetches a URL, extracts readable text,
  and optionally answers a question about it via LLM.
  """
  @behaviour AlexClaw.Skill

  alias AlexClaw.Skills.{Helpers, SkillAPI}

  @max_content_length 8_000

  @impl true
  def version, do: "1.0.0"

  @impl true
  def permissions, do: [:llm, :web_read, :memory_write]

  @impl true
  def description, do: "Fetch URL, extract text, summarize or answer questions (dynamic)"

  @impl true
  def run(args) do
    config = args[:config] || %{}

    browse(
      config["url"] || to_string(args[:input] || ""),
      config["question"],
      build_llm_opts(args)
    )
  end

  defp browse("", _question, _llm_opts), do: {:error, :no_url}

  defp browse(url, question, llm_opts) do
    case fetch_and_extract(url) do
      {:ok, content} -> answer(content, url, question, llm_opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp answer(content, url, question, llm_opts) when question in [nil, ""],
    do: run_summarize(url, content, llm_opts)

  defp answer(content, url, question, llm_opts), do: run_qa(url, content, question, llm_opts)

  # --- Summarize mode ---

  defp run_summarize(url, content, llm_opts) do
    {:ok, system} = SkillAPI.system_prompt(__MODULE__, %{skill: :research})

    prompt = """
    Summarize the following web page content concisely. Focus on key facts and main points.

    URL: #{url}

    Content:
    #{content}
    """

    case SkillAPI.llm_complete(__MODULE__, prompt, llm_opts ++ [tier: :light, system: system]) do
      {:ok, response} ->
        SkillAPI.memory_store(__MODULE__, :web_page, response,
          source: url,
          metadata: %{type: "summary"}
        )

        {:ok, response}

      {:error, reason} ->
        {:error, {:summarize_failed, reason}}
    end
  end

  # --- Q&A mode ---

  defp run_qa(url, content, question, llm_opts) do
    {:ok, system} = SkillAPI.system_prompt(__MODULE__, %{skill: :research})

    prompt = """
    Answer the following question based on the web page content below.
    Be concise and precise. If the answer is not in the content, say so.

    Question: #{question}

    URL: #{url}
    Content:
    #{content}
    """

    case SkillAPI.llm_complete(__MODULE__, prompt, llm_opts ++ [tier: :light, system: system]) do
      {:ok, response} ->
        SkillAPI.memory_store(__MODULE__, :web_page, response,
          source: url,
          metadata: %{type: "qa", question: question}
        )

        {:ok, response}

      {:error, reason} ->
        {:error, {:qa_failed, reason}}
    end
  end

  # --- Fetch & extract ---

  defp fetch_and_extract(url) do
    headers = [
      {"user-agent", "Mozilla/5.0 (compatible; AlexClaw/1.0)"},
      {"accept", "text/html,application/xhtml+xml"}
    ]

    case SkillAPI.http_get(__MODULE__, url,
           headers: headers,
           receive_timeout: 15_000,
           redirect: true,
           max_redirects: 5
         ) do
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
    |> Helpers.sanitize_utf8()
    |> Floki.parse_document!()
    |> Helpers.strip_noise()
    |> Floki.text(sep: "\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.replace(~r/[ \t]+/, " ")
    |> String.trim()
    |> String.slice(0, @max_content_length)
  end

  defp build_llm_opts(%{llm_provider: p}) when p not in [nil, "", "auto"], do: [provider: p]
  defp build_llm_opts(_), do: []
end
