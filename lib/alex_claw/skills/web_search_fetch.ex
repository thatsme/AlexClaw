defmodule AlexClaw.Skills.WebSearchFetch do
  @moduledoc """
  Pure web search skill. Searches DuckDuckGo, fetches top result pages,
  and returns the raw content. No LLM synthesis.

  Use with `llm_transform` for research workflows:
    web_search_fetch → llm_transform → telegram_notify
  """
  @behaviour AlexClaw.Skill
  @impl true
  def external, do: true
  @impl true
  def description, do: "Searches DuckDuckGo and returns raw page content (no LLM)"

  @impl true
  def routes, do: [:on_results, :on_no_results, :on_timeout, :on_error]

  require Logger
  import AlexClaw.Skills.Helpers, only: [sanitize_utf8: 1, strip_noise: 1, parse_int: 2]

  @default_max_results 3
  @max_page_length 3_000

  @impl true
  def run(args) do
    config = args[:config] || %{}
    raw_query = config["query"] || to_string(args[:input] || "")
    query = String.trim(String.slice(raw_query, 0, 200))
    max_results = parse_int(config["max_results"], @default_max_results)

    if query == "" do
      {:error, :no_query}
    else
      case search_ddg(query, max_results) do
        {:ok, results} when results != [] ->
          pages = fetch_pages(results)

          output =
            pages
            |> Enum.with_index(1)
            |> Enum.map_join("\n\n---\n\n", fn {page, i} ->
              "[#{i}] #{page.title}\nURL: #{page.url}\n#{page.content}"
            end)

          {:ok, output, :on_results}

        {:ok, []} ->
          {:ok, "No search results found for: #{query}", :on_no_results}

        {:error, %Req.TransportError{reason: :timeout}} ->
          {:ok, nil, :on_timeout}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp search_ddg(query, max_results) do
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
          |> Enum.take(max_results)
          |> Enum.flat_map(fn element ->
            href = List.first(Floki.attribute(element, "href"))
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
end
