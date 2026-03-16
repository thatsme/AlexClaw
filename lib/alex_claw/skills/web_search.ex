defmodule AlexClaw.Skills.WebSearch do
  @moduledoc """
  Web search skill. Searches DuckDuckGo, fetches top results,
  and synthesizes an answer via LLM.
  """
  @behaviour AlexClaw.Skill
  @impl true
  def description, do: "Searches DuckDuckGo, fetches top results, synthesizes an answer via LLM"
  require Logger
  import AlexClaw.Skills.Helpers, only: [sanitize_utf8: 1, strip_noise: 1]

  alias AlexClaw.{Gateway, Identity, LLM, Memory}

  @max_results 3
  @max_page_length 3_000

  @doc "Workflow-compatible entry point. Uses config query or args[:input] as the search query."
  @impl true
  def run(args) do
    config = args[:config] || %{}
    raw_query = config["query"] || to_string(args[:input] || "")

    query = String.slice(raw_query, 0, 200) |> String.trim()

    if query == "" do
      {:error, :no_query}
    else
      llm_opts =
        case args[:llm_provider] do
          nil -> []
          "" -> []
          "auto" -> []
          provider -> [provider: provider]
        end

      case search_ddg(query) do
        {:ok, results} when results != [] ->
          pages = fetch_pages(results)
          synthesize_for_workflow(query, pages, llm_opts)

        {:ok, []} ->
          {:ok, "No search results found for: #{query}"}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec handle(String.t()) :: :ok
  def handle(query) do
    Logger.info("WebSearch: #{query}", skill: :web_search)
    Gateway.send_message("Searching: #{query}...")

    case run(%{input: query}) do
      {:ok, response} -> Gateway.send_message(response)
      {:error, :no_query} -> Gateway.send_message("No query provided.")
      {:error, reason} ->
        Logger.warning("WebSearch failed: #{inspect(reason)}", skill: :web_search)
        Gateway.send_message("Search failed: #{inspect(reason)}")
    end
  end

  defp search_ddg(query) do
    url = "https://html.duckduckgo.com/html/"

    headers = [
      {"user-agent", "Mozilla/5.0 (compatible; AlexClaw/1.0)"}
    ]

    case Req.post(url, form: [q: query], headers: headers, receive_timeout: 10_000) do
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
    # DuckDuckGo wraps URLs in redirect: //duckduckgo.com/l/?uddg=ENCODED_URL&...
    case URI.decode_query(URI.parse(href).query || "") do
      %{"uddg" => url} -> {:ok, url}
      _ -> if String.starts_with?(href, "http"), do: {:ok, href}, else: :skip
    end
  end

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

    case Req.get(url, headers: headers, receive_timeout: 10_000, redirect: true, max_redirects: 5) do
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


  defp synthesize_for_workflow(query, pages, llm_opts) do
    system = Identity.system_prompt(%{skill: :research})

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

    case LLM.complete(prompt, llm_opts ++ [tier: :medium, system: system]) do
      {:ok, response} ->
        Memory.store(:web_search, response,
          source: "search:#{query}",
          metadata: %{query: query, urls: Enum.map(pages, & &1.url)}
        )
        {:ok, response}

      {:error, reason} ->
        {:error, {:synthesis_failed, reason}}
    end
  end

end
