defmodule AlexClaw.Skills.WebSearchFetch do
  @moduledoc """
  Pure web search skill. Searches DuckDuckGo, fetches top result pages,
  and returns the raw content. No LLM synthesis.

  Use with `llm_transform` for research workflows:
    web_search_fetch → llm_transform → telegram_notify
  """
  @behaviour AlexClaw.Skill
  @impl true
  @spec external() :: boolean()
  def external, do: true
  @impl true
  def description,
    do:
      "Searches DuckDuckGo AND fetches full page content from top results in one step. Returns raw text, no summarization"

  @impl true
  @spec routes() :: [atom()]
  def routes, do: [:on_results, :on_no_results, :on_timeout, :on_error]

  @impl true
  def error_routes, do: [:on_timeout, :on_error]

  @impl true
  def empty_routes, do: [:on_no_results]

  require Logger
  import AlexClaw.Skills.Helpers, only: [sanitize_utf8: 1, strip_noise: 1, parse_int: 2]

  @default_max_results 3
  @max_page_length 3_000

  @impl true
  @spec step_fields() :: [atom()]
  def step_fields, do: [:config]

  @impl true
  @spec config_hint() :: String.t()
  def config_hint, do: ~s|{"query": "search terms", "max_results": 3} — pure search, no LLM|

  @impl true
  @spec config_scaffold() :: map()
  def config_scaffold, do: %{"query" => "", "max_results" => 3}

  @impl true
  @spec config_help() :: String.t()
  def config_help,
    do:
      "query: search terms. max_results: number of pages to fetch (default 3). Returns raw page content — no LLM synthesis. Chain with llm_transform."

  @impl true
  @spec run(map()) :: {:ok, any(), atom()} | {:error, any()}
  def run(args) do
    config = args[:config] || %{}
    raw_query = config["query"] || to_string(args[:input] || "")

    raw_query
    |> String.slice(0, 200)
    |> String.trim()
    |> search(parse_int(config["max_results"], @default_max_results))
  end

  defp search("", _max_results), do: {:error, :no_query}

  defp search(query, max_results) do
    query
    |> search_ddg(max_results)
    |> searched(query)
  end

  defp searched({:ok, []}, query),
    do: {:ok, "No search results found for: #{query}", :on_no_results}

  defp searched({:ok, results}, _query),
    do: {:ok, format_pages(fetch_pages(results)), :on_results}

  defp searched({:error, %Req.TransportError{reason: :timeout}}, _query),
    do: {:ok, nil, :on_timeout}

  defp searched({:error, reason}, _query), do: {:error, reason}

  defp format_pages(pages) do
    pages
    |> Enum.with_index(1)
    |> Enum.map_join("\n\n---\n\n", fn {page, i} ->
      "[#{i}] #{page.title}\nURL: #{page.url}\n#{page.content}"
    end)
  end

  defp search_ddg(query, max_results) do
    url = "https://html.duckduckgo.com/html/"

    headers = [
      {"user-agent", "Mozilla/5.0 (compatible; AlexClaw/1.0)"}
    ]

    case Req.post(url, form: [q: query], headers: headers, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: body}} -> {:ok, parse_results(body, max_results)}
      {:ok, %{status: status}} -> {:error, {:ddg, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_results(body, max_results) do
    body
    |> Floki.parse_document!()
    |> Floki.find(".result__a")
    |> Enum.take(max_results)
    |> Enum.flat_map(&result_entry/1)
  end

  defp result_entry(element) do
    element
    |> Floki.attribute("href")
    |> List.first()
    |> extract_url()
    |> result_entry(Floki.text(element))
  end

  defp result_entry({:ok, url}, title), do: [%{title: title, url: url}]
  defp result_entry(:skip, _title), do: []

  defp extract_url(nil), do: :skip

  defp extract_url(href) do
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
      timeout: 15_000,
      on_timeout: :kill_task
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
end
