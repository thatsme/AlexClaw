defmodule AlexClaw.Memory do
  @moduledoc """
  Persistent knowledge store. Stores facts, summaries, and embeddings.
  Supports hybrid search: pgvector cosine similarity + keyword fallback.
  Embeddings are generated asynchronously under TaskSupervisor.
  """
  require Logger
  import Ecto.Query
  alias AlexClaw.Repo
  alias AlexClaw.Memory.Entry

  @type store_opts :: [source: String.t() | nil, metadata: map(), expires_at: DateTime.t() | nil]

  @doc """
  Store a memory entry. The row is inserted immediately with a nil embedding.
  A background task generates the embedding and updates the row asynchronously.
  """
  @spec store(atom() | String.t(), String.t(), store_opts()) ::
          {:ok, Entry.t()} | {:error, Ecto.Changeset.t()}
  def store(kind, content, opts \\ []) do
    source = Keyword.get(opts, :source)
    metadata = Keyword.get(opts, :metadata, %{})
    expires_at = Keyword.get(opts, :expires_at)

    result =
      %Entry{}
      |> Entry.changeset(%{
        kind: to_string(kind),
        content: content,
        source: source,
        embedding: nil,
        metadata: metadata,
        expires_at: expires_at
      })
      |> Repo.insert()

    case result do
      {:ok, entry} ->
        async_embed(entry)
        {:ok, entry}

      error ->
        error
    end
  end

  @doc """
  Hybrid search: runs both vector similarity and keyword search,
  merges results with vector matches prioritized, deduplicates by ID.
  Falls back to keyword-only when no embedding provider is available.
  """
  @spec search(String.t(), keyword()) :: [Entry.t()]
  def search(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    kind = Keyword.get(opts, :kind)

    case AlexClaw.LLM.embed(query) do
      {:ok, embedding} ->
        vector_results = vector_search(embedding, kind, limit)
        keyword_results = keyword_search(query, kind, limit)

        (vector_results ++ keyword_results)
        |> Enum.uniq_by(& &1.id)
        |> Enum.take(limit)

      {:error, _} ->
        keyword_search(query, kind, limit)
    end
  end

  @doc "Check if a content string (or URL) already exists in memory."
  @spec exists?(String.t()) :: boolean()
  def exists?(content_or_source) do
    Entry
    |> where([e], e.content == ^content_or_source or e.source == ^content_or_source)
    |> Repo.exists?()
  end

  @doc "List recent memories, optionally filtered by kind."
  @spec recent(keyword()) :: [Entry.t()]
  def recent(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    kind = Keyword.get(opts, :kind)

    Entry
    |> maybe_filter_kind(kind)
    |> order_by([e], desc: e.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Re-embed all memories with nil embeddings. Runs in the background under TaskSupervisor.
  Returns `{:ok, count}` where count is the number of entries queued for processing.

  Options:
    - `:batch_size` — entries per batch (default: 20)
    - `:max_concurrency` — parallel embedding tasks per batch (default: 2)
  """
  @spec reembed_all(keyword()) :: {:ok, non_neg_integer()}
  def reembed_all(opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, 20)
    max_concurrency = Keyword.get(opts, :max_concurrency, 2)

    entries =
      Entry
      |> where([e], is_nil(e.embedding))
      |> Repo.all()

    count = length(entries)

    if count > 0 do
      caller = self()

      Task.Supervisor.start_child(AlexClaw.TaskSupervisor, fn ->
        sandbox_allow(caller)
        Logger.info("Re-embedding #{count} memories...")

        entries
        |> Enum.chunk_every(batch_size)
        |> Enum.each(fn batch ->
          batch
          |> Task.async_stream(
            fn entry -> embed_entry(entry) end,
            max_concurrency: max_concurrency,
            timeout: 30_000,
            on_timeout: :kill_task
          )
          |> Stream.run()
        end)

        Logger.info("Re-embedding complete: processed #{count} entries")
      end)
    end

    {:ok, count}
  end

  # --- Internal ---

  defp async_embed(%Entry{} = entry) do
    caller = self()

    Task.Supervisor.start_child(AlexClaw.TaskSupervisor, fn ->
      sandbox_allow(caller)
      embed_entry(entry)
    end)
  end

  defp sandbox_allow(caller) do
    if Application.get_env(:alex_claw, AlexClaw.Repo)[:pool] == Ecto.Adapters.SQL.Sandbox do
      Ecto.Adapters.SQL.Sandbox.allow(AlexClaw.Repo, caller, self())
    end
  end

  defp embed_entry(%Entry{id: id, content: content}) do
    case AlexClaw.LLM.embed(content) do
      {:ok, vector} when is_list(vector) ->
        Entry
        |> Repo.get(id)
        |> Entry.changeset(%{embedding: vector})
        |> Repo.update()

      {:error, reason} ->
        Logger.warning("Embedding failed for memory #{id}: #{inspect(reason)}")
        :ok
    end
  end

  defp vector_search(embedding, kind, limit) do
    Entry
    |> maybe_filter_kind(kind)
    |> where([e], not is_nil(e.embedding))
    |> order_by([e], fragment("embedding <=> ?", ^embedding))
    |> limit(^limit)
    |> Repo.all()
  end

  defp keyword_search(query, kind, limit) do
    pattern = "%#{query}%"

    Entry
    |> maybe_filter_kind(kind)
    |> where([e], ilike(e.content, ^pattern))
    |> order_by([e], desc: e.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  defp maybe_filter_kind(queryable, nil), do: queryable
  defp maybe_filter_kind(queryable, kind), do: where(queryable, [e], e.kind == ^to_string(kind))
end
