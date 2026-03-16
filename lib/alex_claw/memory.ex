defmodule AlexClaw.Memory do
  @moduledoc """
  Persistent knowledge store. Stores facts, summaries, and embeddings.
  Supports semantic search via pgvector cosine similarity.
  """
  import Ecto.Query
  alias AlexClaw.Repo
  alias AlexClaw.Memory.Entry

  @type store_opts :: [source: String.t() | nil, metadata: map(), expires_at: DateTime.t() | nil]

  @doc "Store a memory entry with optional embedding."
  @spec store(atom() | String.t(), String.t(), store_opts()) :: {:ok, Entry.t()} | {:error, Ecto.Changeset.t()}
  def store(kind, content, opts \\ []) do
    source = Keyword.get(opts, :source)
    metadata = Keyword.get(opts, :metadata, %{})
    expires_at = Keyword.get(opts, :expires_at)

    embedding =
      case AlexClaw.LLM.embed(content) do
        {:ok, vec} -> vec
        _ -> nil
      end

    %Entry{}
    |> Entry.changeset(%{
      kind: to_string(kind),
      content: content,
      source: source,
      embedding: embedding,
      metadata: metadata,
      expires_at: expires_at
    })
    |> Repo.insert()
  end

  @doc "Search memories by semantic similarity. Falls back to keyword search if no embeddings."
  @spec search(String.t(), keyword()) :: [Entry.t()]
  def search(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    kind = Keyword.get(opts, :kind)

    case AlexClaw.LLM.embed(query) do
      {:ok, embedding} when not is_nil(embedding) ->
        vector_search(embedding, kind, limit)

      _ ->
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

  # --- Internal ---

  defp vector_search(embedding, kind, limit) do
    Entry
    |> maybe_filter_kind(kind)
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
