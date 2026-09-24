defmodule AlexClaw.Skills.WebSearch do
  @moduledoc """
  Web search skill. Searches DuckDuckGo, fetches top results,
  and synthesizes an answer via LLM.
  """
  @behaviour AlexClaw.Skill
  @impl true
  @spec external() :: boolean()
  def external, do: true
  @impl true
  @spec description() :: String.t()
  def description,
    do:
      "Searches DuckDuckGo and returns short snippets: titles and brief descriptions only. Does NOT return full page content"

  @impl true
  @spec routes() :: [atom()]
  def routes, do: [:on_results, :on_no_results, :on_timeout, :on_error]

  @impl true
  def error_routes, do: [:on_timeout, :on_error]

  @impl true
  def empty_routes, do: [:on_no_results]
  require Logger
  import AlexClaw.Skills.Helpers, only: [llm_opts: 1, sanitize_utf8: 1, strip_noise: 1]

  alias AlexClaw.{Gateway, Identity, LLM, Memory}

  @max_results 3
  @max_page_length 3_000

  @impl true
  @spec step_fields() :: [atom()]
  def step_fields, do: [:llm_tier, :llm_model, :prompt_template, :config]

  @impl true
  @spec config_hint() :: String.t()
  def config_hint, do: ~s|{"query": "search terms"}|

  @impl true
  @spec config_scaffold() :: map()
  def config_scaffold, do: %{"query" => ""}

  @impl true
  @spec config_help() :: String.t()
  def config_help,
    do: "query: the search terms. Leave empty to use {input} from the previous step."

  @doc "Workflow-compatible entry point. Uses config query or args[:input] as the search query."
  @impl true
  @spec run(map()) :: {:ok, String.t() | nil, atom()} | {:error, any()}
  def run(args) do
    config = args[:config] || %{}
    raw_query = config["query"] || to_string(args[:input] || "")

    raw_query
    |> String.slice(0, 200)
    |> String.trim()
    |> search(llm_opts(args))
  end

  defp search("", _llm_opts), do: {:error, :no_query}

  defp search(query, llm_opts) do
    query
    |> search_ddg()
    |> searched(query, llm_opts)
  end

  defp searched({:ok, []}, query, _llm_opts),
    do: {:ok, "No search results found for: #{query}", :on_no_results}

  defp searched({:ok, results}, query, llm_opts),
    do: synthesize_for_workflow(query, fetch_pages(results), llm_opts)

  defp searched({:error, %Req.TransportError{reason: :timeout}}, _query, _llm_opts),
    do: {:ok, nil, :on_timeout}

  defp searched({:error, reason}, _query, _llm_opts), do: {:error, reason}

  @spec handle(String.t(), keyword()) :: :ok
  def handle(query, opts \\ []) do
    Logger.info("WebSearch: #{query}", skill: :web_search)
    gateway_opts = Keyword.take(opts, [:gateway, :chat_id])
    Gateway.send_message("Searching: #{query}...", gateway_opts)

    tier = Keyword.get(opts, :tier, resolve_tier())
    provider = Keyword.get(opts, :provider, resolve_provider())

    case run(%{input: query, llm_provider: provider, llm_tier: tier}) do
      {:ok, response, _branch} ->
        Gateway.send_message(response, gateway_opts)

      {:error, :no_query} ->
        Gateway.send_message("No query provided.", gateway_opts)

      {:error, reason} ->
        Logger.warning("WebSearch failed: #{inspect(reason)}", skill: :web_search)
        Gateway.send_message("Search failed: #{inspect(reason)}", gateway_opts)
    end
  end

  defp resolve_tier,
    do: String.to_existing_atom(AlexClaw.Config.get("skill.web_search.tier") || "medium")

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
      {:ok, %{status: 200, body: body}} -> {:ok, parse_results(body)}
      {:ok, %{status: status}} -> {:error, {:ddg, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_results(body) do
    body
    |> Floki.parse_document!()
    |> Floki.find(".result__a")
    |> Enum.take(@max_results)
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
          {:ok, text} ->
            %{
              title: title,
              url: url,
              content: AlexClaw.ContentSanitizer.sanitize(text, skill: "web_search")
            }

          {:error, _} ->
            %{title: title, url: url, content: "(failed to fetch)"}
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
