defmodule AlexClaw.Skills.Dynamic.WebSearchV2 do
  @moduledoc """
  Dynamic web search skill. Searches DuckDuckGo, fetches top results,
  and synthesizes an answer via LLM.
  """
  @behaviour AlexClaw.Skill

  import AlexClaw.Skills.Helpers, only: [sanitize_utf8: 1, strip_noise: 1]
  alias AlexClaw.Skills.SkillAPI

  @max_results 3
  @max_page_length 3_000

  @impl true
  def version, do: "1.0.0"

  @impl true
  def permissions, do: [:llm, :web_read, :memory_write]

  @impl true
  def description, do: "DuckDuckGo search with LLM synthesis (dynamic)"

  @impl true
  def run(args) do
    config = args[:config] || %{}
    raw_query = config["query"] || to_string(args[:input] || "")
    query = String.slice(raw_query, 0, 200) |> String.trim()

    if query == "" do
      {:error, :no_query}
    else
      llm_opts = build_llm_opts(args)

      case search_ddg(query) do
        {:ok, results} when results != [] ->
          pages = fetch_pages(results)
          synthesize(query, pages, llm_opts)

        {:ok, []} ->
          {:ok, "No search results found for: #{query}"}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # --- DuckDuckGo search ---

  defp search_ddg(query) do
    headers = [{"user-agent", "Mozilla/5.0 (compatible; AlexClaw/1.0)"}]

    case SkillAPI.http_post(__MODULE__, "https://html.duckduckgo.com/html/",
           form: [q: query], headers: headers, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: body}} ->
        results =
          body
          |> Floki.parse_document!()
          |> Floki.find(".result__a")
          |> Enum.take(@max_results)
          |> Enum.flat_map(fn element ->
            href = Floki.attribute(element, "href") |> List.first()
            title = Floki.text(element)

            case extract_url(href) do
              {:ok, url} -> [%{title: title, url: url}]
              :skip -> []
            end
          end)

        {:ok, results}

      {:ok, %{status: status}} ->
        {:error, {:ddg, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_url(nil), do: :skip

  defp extract_url(href) do
    case URI.decode_query(URI.parse(href).query || "") do
      %{"uddg" => url} -> {:ok, url}
      _ -> if String.starts_with?(href, "http"), do: {:ok, href}, else: :skip
    end
  end

  # --- Page fetching ---

  defp fetch_pages(results) do
    results
    |> Task.async_stream(
      fn %{title: title, url: url} ->
        case fetch_text(url) do
          {:ok, text} -> %{title: title, url: url, content: text}
          {:error, _} -> %{title: title, url: url, content: "(failed to fetch)"}
        end
      end,
      max_concurrency: 3,
      timeout: 15_000
    )
    |> Enum.flat_map(fn
      {:ok, page} -> [page]
      _ -> []
    end)
  end

  defp fetch_text(url) do
    headers = [
      {"user-agent", "Mozilla/5.0 (compatible; AlexClaw/1.0)"},
      {"accept", "text/html"}
    ]

    case SkillAPI.http_get(__MODULE__, url,
           headers: headers, receive_timeout: 10_000, redirect: true, max_redirects: 5) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        text =
          body
          |> sanitize_utf8()
          |> Floki.parse_document!()
          |> strip_noise()
          |> Floki.text(sep: "\n")
          |> String.replace(~r/\n{3,}/, "\n\n")
          |> String.replace(~r/[ \t]+/, " ")
          |> String.trim()
          |> String.slice(0, @max_page_length)

        {:ok, text}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- LLM synthesis ---

  defp synthesize(query, pages, llm_opts) do
    {:ok, system} = SkillAPI.system_prompt(__MODULE__, %{skill: :research})

    sources =
      pages
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n---\n\n", fn {page, i} ->
        "[#{i}] #{page.title}\nURL: #{page.url}\n#{page.content}"
      end)

    prompt = """
    Answer the following question using the web search results below.
    Be concise, factual, and cite which source(s) you used.
    If the sources don't contain enough info, say so.

    Question: #{query}

    Search results:
    #{sources}
    """

    case SkillAPI.llm_complete(__MODULE__, prompt, llm_opts ++ [tier: :medium, system: system]) do
      {:ok, response} ->
        SkillAPI.memory_store(__MODULE__, :web_search, response,
          source: "search:#{query}",
          metadata: %{query: query, urls: Enum.map(pages, & &1.url)}
        )

        {:ok, response}

      {:error, reason} ->
        {:error, {:synthesis_failed, reason}}
    end
  end

  defp build_llm_opts(%{llm_provider: p}) when p not in [nil, "", "auto"], do: [provider: p]
  defp build_llm_opts(_), do: []
end
