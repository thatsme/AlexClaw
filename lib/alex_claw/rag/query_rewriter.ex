defmodule AlexClaw.RAG.QueryRewriter do
  @moduledoc """
  Rewrites user queries into multiple semantic variants for better RAG retrieval.
  Uses a light-tier LLM call with ETS caching to minimize latency.
  Always succeeds — falls back to the original query on any error.
  """
  require Logger

  @cache_table :rag_query_rewrite_cache
  @cache_ttl_ms 300_000

  @doc "Initialize the ETS cache table. Called from Application.start/2."
  @spec init_cache() :: :ok
  def init_cache do
    if :ets.whereis(@cache_table) == :undefined do
      :ets.new(@cache_table, [:named_table, :public, :set])
    end

    :ok
  end

  @doc """
  Rewrite a query into 1-3 semantic variants for broader retrieval.
  Returns the original query as-is on any failure.

  Options:
    - `:max_variants` — maximum number of variants to return (default: 3)
  """
  @spec rewrite(String.t(), keyword()) :: [String.t()]
  def rewrite(query, opts \\ []) do
    max = Keyword.get(opts, :max_variants, 3)

    case cache_get(query) do
      {:ok, cached} ->
        Enum.take(cached, max)

      :miss ->
        variants = generate_variants(query, max)
        cache_put(query, variants)
        variants
    end
  end

  defp generate_variants(query, max) do
    prompt = """
    You are a search query optimizer. Given a user question, generate #{max} alternative search queries that would find relevant documents in a knowledge base.

    Rules:
    - Each query should use different terminology or phrasing
    - Include technical synonyms and related concepts
    - One query should be more specific, one more general
    - Output one query per line, nothing else

    Examples:
    User: "how does GenServer work"
    1. GenServer OTP behaviour callbacks init handle_call handle_cast
    2. Elixir process state management synchronous asynchronous calls
    3. OTP generic server implementation pattern

    User: "fix SQL injection"
    1. SQL injection prevention parameterized queries prepared statements
    2. database security input sanitization Ecto query safety
    3. prevent malicious SQL input validation escaping

    User: "#{String.replace(query, "\"", "'")}"
    """

    case AlexClaw.LLM.complete(prompt, tier: :light) do
      {:ok, response} ->
        variants =
          response
          |> String.split("\n", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.map(&strip_numbering/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.take(max)

        case variants do
          [] -> [query]
          _ -> variants
        end

      {:error, reason} ->
        Logger.warning("Query rewrite failed: #{inspect(reason)}, using original query")
        [query]
    end
  end

  defp strip_numbering(text) do
    Regex.replace(~r/^\d+[\.\)]\s*/, text, "")
  end

  # --- ETS Cache ---

  defp cache_get(query) do
    init_cache()

    case :ets.lookup(@cache_table, query) do
      [{^query, variants, inserted_at}] ->
        if System.monotonic_time(:millisecond) - inserted_at < @cache_ttl_ms do
          {:ok, variants}
        else
          :ets.delete(@cache_table, query)
          :miss
        end

      [] ->
        :miss
    end
  end

  defp cache_put(query, variants) do
    init_cache()
    :ets.insert(@cache_table, {query, variants, System.monotonic_time(:millisecond)})
  end
end
