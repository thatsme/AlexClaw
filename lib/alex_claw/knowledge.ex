defmodule AlexClaw.Knowledge do
  @moduledoc """
  Knowledge base store for documentation, guides, and reference material.
  Separate from Memory (news/facts) to keep embeddings cleanly partitioned.
  Supports hybrid search: pgvector cosine similarity + keyword fallback.
  Embeddings are generated asynchronously under TaskSupervisor.
  """
  require Logger
  import Ecto.Query
  alias AlexClaw.Knowledge.{EmbedThrottle, Entry}
  alias AlexClaw.RAG.{Chunker, QueryRewriter}
  alias AlexClaw.Repo
  alias Ecto.Adapters.SQL.Sandbox

  @default_embedding_model "text-embedding-004"

  @type store_opts :: [source: String.t() | nil, metadata: map(), expires_at: DateTime.t() | nil]

  @spec store(atom() | String.t(), String.t(), store_opts()) ::
          {:ok, Entry.t()} | {:error, Ecto.Changeset.t()}
  def store(kind, content, opts \\ []) do
    source = Keyword.get(opts, :source)
    metadata = Keyword.get(opts, :metadata, %{})
    expires_at = Keyword.get(opts, :expires_at)
    kind_str = to_string(kind)

    base_attrs = %{
      kind: kind_str,
      content: content,
      source: source,
      embedding: nil,
      metadata: metadata,
      expires_at: expires_at
    }

    if Chunker.should_chunk?(content) do
      store_with_chunks(base_attrs)
    else
      store_single(base_attrs)
    end
  end

  defp store_single(attrs) do
    result = %Entry{} |> Entry.changeset(attrs) |> Repo.insert()

    case result do
      {:ok, entry} ->
        async_embed(entry)
        {:ok, entry}

      error ->
        error
    end
  end

  defp store_with_chunks(attrs) do
    parent_result = %Entry{} |> Entry.changeset(attrs) |> Repo.insert()

    case parent_result do
      {:ok, parent} ->
        chunks = Chunker.chunk(attrs.content)

        Enum.each(chunks, fn %{text: text, index: idx} ->
          chunk_attrs = %{
            kind: attrs.kind,
            content: text,
            source: attrs.source,
            embedding: nil,
            metadata: Map.merge(attrs.metadata || %{}, %{"chunk" => true}),
            expires_at: attrs.expires_at,
            parent_id: parent.id,
            chunk_index: idx
          }

          %Entry{}
          |> Entry.changeset(chunk_attrs)
          |> Repo.insert()
          |> embed_inserted_chunk(idx)
        end)

        {:ok, parent}

      error ->
        error
    end
  end

  @spec search(String.t(), keyword()) :: [Entry.t()]
  def search(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    kind = Keyword.get(opts, :kind)
    min_score = Keyword.get(opts, :min_score)
    rewrite = Keyword.get(opts, :rewrite, false)

    queries = if rewrite, do: QueryRewriter.rewrite(query), else: [query]

    keyword_results = keyword_search(query, kind, limit)

    vector_results =
      queries
      |> Enum.flat_map(fn q ->
        case AlexClaw.LLM.embed(q) do
          {:ok, embedding} -> vector_search(embedding, kind, limit, min_score)
          {:error, _} -> []
        end
      end)
      |> Enum.uniq_by(& &1.id)

    merge_results(keyword_results, vector_results, limit)
    |> deduplicate_chunks()
  end

  @spec exists?(String.t()) :: boolean()
  def exists?(source_url) do
    Entry
    |> where([e], e.source == ^source_url)
    |> Repo.exists?()
  end

  @doc """
  Delete entries of `kind` whose source starts with `prefix`.

  Both arguments are required and must be non-empty: there is deliberately no way
  to express an unscoped delete through this function. `prefix` is matched
  literally — LIKE metacharacters in it are escaped, so a prefix containing `%`
  or `_` matches only those characters.
  """
  @spec delete_by_source_prefix(String.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, :invalid_scope}
  def delete_by_source_prefix(kind, prefix)
      when is_binary(kind) and is_binary(prefix) and kind != "" and prefix != "" do
    pattern = escape_like(prefix) <> "%"

    {count, _returned} =
      Entry
      |> where([e], e.kind == ^kind)
      |> where([e], like(e.source, ^pattern))
      |> Repo.delete_all()

    {:ok, count}
  end

  def delete_by_source_prefix(_kind, _prefix), do: {:error, :invalid_scope}

  # The escape character itself has to go first, or it would escape the escapes.
  defp escape_like(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

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

  @spec count(atom() | String.t() | nil) :: non_neg_integer()
  def count(kind \\ nil) do
    Entry
    |> maybe_filter_kind(kind)
    |> Repo.aggregate(:count)
  end

  @spec reembed_all(keyword()) :: {:ok, non_neg_integer()}
  def reembed_all(opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, 20)
    max_concurrency = Keyword.get(opts, :max_concurrency, 2)
    current_model = current_embedding_model()

    entries =
      Entry
      |> where(
        [e],
        is_nil(e.embedding) or is_nil(e.embedding_model) or
          e.embedding_model != ^current_model
      )
      |> Repo.all()

    count = length(entries)

    # Same guard as async_embed/1: with no enabled provider the pass can only log
    # failures, and under the test sandbox the task outlives the caller that lent
    # it a connection, breaking whichever test runs next.
    if count > 0 and embedding_possible?() do
      caller = self()

      Task.Supervisor.start_child(AlexClaw.TaskSupervisor, fn ->
        sandbox_allow(caller)
        Logger.info("Re-embedding #{count} knowledge entries...")

        entries
        |> Enum.chunk_every(batch_size)
        |> Enum.each(&embed_batch(&1, max_concurrency))

        Logger.info("Re-embedding complete: processed #{count} knowledge entries")
      end)
    end

    {:ok, count}
  end

  @doc "Count entries whose embedding was generated by a different model than the given one."
  @spec stale_embedding_count(String.t()) :: non_neg_integer()
  def stale_embedding_count(current_model) do
    Entry
    |> where([e], not is_nil(e.embedding))
    |> where([e], is_nil(e.embedding_model) or e.embedding_model != ^current_model)
    |> Repo.aggregate(:count)
  end

  # --- Internal ---

  defp deduplicate_chunks(entries) do
    {chunks, standalone} = Enum.split_with(entries, &(not is_nil(&1.parent_id)))
    seen_parents = Enum.uniq_by(chunks, & &1.parent_id)
    standalone ++ seen_parents
  end

  defp async_embed(%Entry{} = entry), do: async_embed(entry, embedding_possible?())

  # No enabled provider means embed/2 can only return :no_embedding_provider, so
  # spawning a task achieves nothing. Under the test sandbox it does worse than
  # nothing: the task borrows the calling test's connection and keeps querying
  # after the test exits and the connection is checked back in.
  defp async_embed(%Entry{}, false), do: :ok

  defp async_embed(%Entry{} = entry, true) do
    caller = self()

    Task.Supervisor.start_child(AlexClaw.TaskSupervisor, fn ->
      sandbox_allow(caller)

      # Throttle concurrent embedding requests to avoid overwhelming Ollama/Finch pool
      case EmbedThrottle.acquire() do
        :ok ->
          try do
            embed_entry(entry)
          after
            EmbedThrottle.release()
          end

        :drop ->
          # Queue is full — schedule a retry via reembed_all later
          Logger.warning("Embedding throttled for entry #{entry.id}, will retry via reembed_all")
      end
    end)
  end

  defp embedding_possible? do
    Repo.exists?(from(p in AlexClaw.LLM.Provider, where: p.enabled == true))
  end

  # Both the write path and the staleness check must resolve the model name the
  # same way. When they disagreed — the write falling back to a default and the
  # check comparing against "" — every entry was stale the moment it was
  # embedded, and reembed_all/1 re-embedded the whole table on every run.
  defp current_embedding_model do
    AlexClaw.Config.get("embedding.model") || @default_embedding_model
  end

  defp embed_inserted_chunk({:ok, chunk_entry}, _idx), do: async_embed(chunk_entry)

  defp embed_inserted_chunk({:error, reason}, idx) do
    Logger.warning("Failed to insert chunk #{idx}: #{inspect(reason)}")
  end

  defp embed_batch(batch, max_concurrency) do
    batch
    |> Task.async_stream(&embed_entry/1,
      max_concurrency: max_concurrency,
      timeout: 30_000,
      on_timeout: :kill_task
    )
    |> Stream.run()
  end

  @stopwords ~w(the and for how does what which with from that this are was were can)

  defp stopword_or_short?(term) do
    String.length(term) < 3 or String.downcase(term) in @stopwords
  end

  defp sandbox_allow(caller) do
    if Application.get_env(:alex_claw, AlexClaw.Repo)[:pool] == Ecto.Adapters.SQL.Sandbox do
      Sandbox.allow(AlexClaw.Repo, caller, self())
    end
  end

  defp embed_entry(%Entry{id: id, content: content}) do
    model = current_embedding_model()

    case AlexClaw.LLM.embed(content) do
      {:ok, vector} when is_list(vector) ->
        case Repo.get(Entry, id) do
          nil ->
            :ok

          entry ->
            entry
            |> Entry.changeset(%{
              embedding: vector,
              embedding_model: model,
              embedding_dim: length(vector),
              embedded_at: DateTime.utc_now() |> DateTime.truncate(:second)
            })
            |> Repo.update()
        end

      {:error, reason} ->
        Logger.warning("Embedding failed for knowledge entry #{id}: #{inspect(reason)}")
        :ok
    end
  end

  defp merge_results(keyword_results, vector_results, limit) do
    # Keyword matches are more precise for documentation, so they go first.
    # Then fill with vector results that weren't already found by keyword.
    keyword_ids = MapSet.new(keyword_results, & &1.id)

    new_vector =
      Enum.reject(vector_results, fn e -> MapSet.member?(keyword_ids, e.id) end)

    Enum.take(keyword_results ++ new_vector, limit)
  end

  defp vector_search(embedding, kind, limit, min_score \\ nil) do
    query =
      Entry
      |> maybe_filter_kind(kind)
      |> where([e], not is_nil(e.embedding))
      |> order_by([e], fragment("embedding <=> ?", ^embedding))
      |> limit(^limit)

    query =
      if min_score do
        where(query, [e], fragment("1 - (embedding <=> ?) >= ?", ^embedding, ^min_score))
      else
        query
      end

    Repo.all(query)
  end

  defp keyword_search(query, kind, limit) do
    terms =
      query
      |> String.replace(~r/[?!.,;:()\[\]{}"']/, " ")
      |> String.split(~r/\s+/, trim: true)
      |> Enum.reject(&stopword_or_short?/1)
      |> Enum.take(5)

    case terms do
      [] ->
        []

      terms ->
        Enum.reduce(terms, maybe_filter_kind(Entry, kind), fn term, q ->
          pattern = "%#{term}%"
          where(q, [e], ilike(e.content, ^pattern))
        end)
        |> order_by([e], desc: e.inserted_at)
        |> limit(^limit)
        |> Repo.all()
    end
  end

  defp maybe_filter_kind(queryable, nil), do: queryable
  defp maybe_filter_kind(queryable, kind), do: where(queryable, [e], e.kind == ^to_string(kind))
end
