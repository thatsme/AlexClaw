defmodule AlexClaw.Knowledge do
  @moduledoc """
  Knowledge base store for documentation, guides, and reference material.
  Separate from Memory (news/facts) to keep embeddings cleanly partitioned.
  Supports hybrid search: pgvector cosine similarity + keyword fallback.
  Embeddings are generated asynchronously under TaskSupervisor.
  """
  require Logger
  import Ecto.Query
  alias AlexClaw.Repo
  alias AlexClaw.Knowledge.Entry

  @type store_opts :: [source: String.t() | nil, metadata: map(), expires_at: DateTime.t() | nil]

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

  @spec search(String.t(), keyword()) :: [Entry.t()]
  def search(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    kind = Keyword.get(opts, :kind)

    keyword_results = keyword_search(query, kind, limit)

    case AlexClaw.LLM.embed(query) do
      {:ok, embedding} ->
        vector_results = vector_search(embedding, kind, limit)
        merge_results(keyword_results, vector_results, limit)

      {:error, _} ->
        keyword_results
    end
  end

  @spec exists?(String.t()) :: boolean()
  def exists?(source_url) do
    Entry
    |> where([e], e.source == ^source_url)
    |> Repo.exists?()
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

    entries =
      Entry
      |> where([e], is_nil(e.embedding))
      |> Repo.all()

    count = length(entries)

    if count > 0 do
      caller = self()

      Task.Supervisor.start_child(AlexClaw.TaskSupervisor, fn ->
        sandbox_allow(caller)
        Logger.info("Re-embedding #{count} knowledge entries...")

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

        Logger.info("Re-embedding complete: processed #{count} knowledge entries")
      end)
    end

    {:ok, count}
  end

  # --- Internal ---

  defp async_embed(%Entry{} = entry) do
    caller = self()

    Task.Supervisor.start_child(AlexClaw.TaskSupervisor, fn ->
      sandbox_allow(caller)

      # Throttle concurrent embedding requests to avoid overwhelming Ollama/Finch pool
      case AlexClaw.Knowledge.EmbedThrottle.acquire() do
        :ok ->
          try do
            embed_entry(entry)
          after
            AlexClaw.Knowledge.EmbedThrottle.release()
          end

        :drop ->
          # Queue is full — schedule a retry via reembed_all later
          Logger.warning("Embedding throttled for entry #{entry.id}, will retry via reembed_all")
      end
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
        case Repo.get(Entry, id) do
          nil -> :ok
          entry -> entry |> Entry.changeset(%{embedding: vector}) |> Repo.update()
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

  defp vector_search(embedding, kind, limit) do
    Entry
    |> maybe_filter_kind(kind)
    |> where([e], not is_nil(e.embedding))
    |> order_by([e], fragment("embedding <=> ?", ^embedding))
    |> limit(^limit)
    |> Repo.all()
  end

  defp keyword_search(query, kind, limit) do
    terms =
      query
      |> String.replace(~r/[?!.,;:()\[\]{}"']/, " ")
      |> String.split(~r/\s+/, trim: true)
      |> Enum.reject(fn t -> String.length(t) < 3 end)
      |> Enum.reject(fn t -> String.downcase(t) in ~w(the and for how does what which with from that this are was were can) end)
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
