defmodule AlexClaw.Skills.WebSearch do
  @moduledoc """
  Web search skill. Searches DuckDuckGo, fetches top results,
  and synthesizes an answer via LLM.
  """
  @behaviour AlexClaw.Skill
  @impl true
  @spec description() :: String.t()
  def description, do: "Searches DuckDuckGo, fetches top results, synthesizes an answer via LLM"

  @impl true
  @spec routes() :: [atom()]
  def routes, do: [:on_results, :on_no_results, :on_timeout, :on_error]
  require Logger
  import AlexClaw.Skills.Helpers, only: [sanitize_utf8: 1, strip_noise: 1]

  alias AlexClaw.{Gateway, Identity, LLM, Memory}

  @max_results 3
  @max_page_length 3_000

  @doc "Workflow-compatible entry point. Uses config query or args[:input] as the search query."
  @impl true
  @spec run(map()) :: {:ok, String.t() | nil, atom()} | {:error, any()}
  def run(args) do
    config = args[:config] || %{}
    raw_query = config["query"] || to_string(args[:input] || "")

    query = String.trim(String.slice(raw_query, 0, 200))

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

      llm_opts =
        case args[:llm_tier] do
          nil -> llm_opts
          tier when is_atom(tier) -> [{:tier, tier} | llm_opts]
          tier when is_binary(tier) -> [{:tier, String.to_existing_atom(tier)} | llm_opts]
        end

      case search_ddg(query) do
        {:ok, results} when results != [] ->
          pages = fetch_pages(results)
          synthesize_for_workflow(query, pages, llm_opts)

        {:ok, []} ->
          {:ok, "No search results found for: #{query}", :on_no_results}

        {:error, %Req.TransportError{reason: :timeout}} ->
          {:ok, nil, :on_timeout}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec handle(String.t(), keyword()) :: :ok
  def handle(query, opts \\ []) do
    Logger.info("WebSearch: #{query}", skill: :web_search)
    gateway_opts = Keyword.take(opts, [:gateway, :chat_id])
    Gateway.send_message("Searching: #{query}...", gateway_opts)

    tier = Keyword.get(opts, :tier, resolve_tier())
    provider = Keyword.get(opts, :provider, resolve_provider())

    case run(%{input: query, llm_provider: provider, llm_tier: tier}) do
      {:ok, response, _branch} -> Gateway.send_message(response, gateway_opts)
      {:error, :no_query} -> Gateway.send_message("No query provided.", gateway_opts)
      {:error, reason} ->
        Logger.warning("WebSearch failed: #{inspect(reason)}", skill: :web_search)
        Gateway.send_message("Search failed: #{inspect(reason)}", gateway_opts)
    end
  end

  defp resolve_tier, do: String.to_existing_atom(AlexClaw.Config.get("skill.web_search.tier") || "medium")
  defp resolve_provider do
    case AlexClaw.Config.get("skill.web_search.provider") do
      p when p in [nil, "", "auto"] -> nil
      p -> p
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

    default_tier = resolve_tier()
    case LLM.complete(prompt, [{:tier, default_tier}, {:system, system}] ++ llm_opts) do
      {:ok, response} ->
        Memory.store(:web_search, response,
          source: "search:#{query}",
          metadata: %{query: query, urls: Enum.map(pages, & &1.url)}
        )
        {:ok, response, :on_results}

      {:error, reason} ->
        {:error, {:synthesis_failed, reason}}
    end
  end

end
