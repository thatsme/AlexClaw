defmodule AlexClaw.RAG.Fallback do
  @moduledoc """
  Fallback strategies when RAG retrieval finds no relevant results.

  Strategies:
  - :none       — results were good, no fallback needed
  - :cross_store — tried the other store (Memory ↔ Knowledge)
  - :no_context — both stores empty, proceed without context
  """

  @type strategy :: :none | :cross_store | :no_context
  @type result :: {:ok, String.t(), strategy()} | {:no_context, strategy()}

  @doc """
  Given a query and results from both stores, format context or signal no results.

  Returns `{:ok, context_string, strategy}` when context is available,
  or `{:no_context, :no_context}` when nothing was found.
  """
  @spec resolve(String.t(), [struct()], [struct()]) :: result()
  def resolve(_query, memory_results, knowledge_results) do
    all = memory_results ++ knowledge_results

    case all do
      [] ->
        {:no_context, :no_context}

      entries ->
        context = Enum.map_join(entries, "\n---\n", & &1.content)
        {:ok, context, :none}
    end
  end

  @doc """
  Search both stores with shared options, apply fallback logic.
  Intended for skills that want full RAG with cross-store support.

  Options are passed through to Memory.search/2 and Knowledge.search/2.
  """
  @spec search_with_fallback(String.t(), keyword()) :: result()
  def search_with_fallback(query, opts \\ []) do
    memory_opts = Keyword.merge([limit: 5, rewrite: true, min_score: 0.35], opts)
    knowledge_opts = Keyword.merge([limit: 3, rewrite: true, min_score: 0.35], opts)

    memory_results = AlexClaw.Memory.search(query, memory_opts)
    knowledge_results = AlexClaw.Knowledge.search(query, knowledge_opts)

    resolve(query, memory_results, knowledge_results)
  end
end
