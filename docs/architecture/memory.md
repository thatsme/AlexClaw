# Memory & Knowledge

AlexClaw maintains two separate data stores for persistent information: **Memory** (ephemeral facts and observations) and **Knowledge** (stable reference material).

## Memory — `AlexClaw.Memory`

Stores news items, conversation summaries, facts, and observations.

| Field | Description |
|---|---|
| `kind` | `fact`, `summary`, `news_item`, `conversation`, `security_review`, `web_search`, `web_page` |
| `content` | The stored text |
| `source` | URL, feed name, or skill name |
| `embedding` | pgvector column (768 dimensions, HNSW index, cosine distance) |
| `metadata` | JSONB (feed name, relevance score, etc.) |
| `expires_at` | Optional TTL |
| `embedding_model` | Which model generated the embedding (e.g. `nomic-embed-text-v1.5`) |
| `embedding_dim` | Dimension count of the stored vector |
| `embedded_at` | When the embedding was generated |
| `parent_id` | Self-referential FK — links chunks to their parent entry |
| `chunk_index` | Position of this chunk within the parent (0-based) |

## Knowledge — `AlexClaw.Knowledge`

Stores documentation, guides, and reference material. Same schema as Memory but in a separate table (`knowledge_entries`), isolated from news and conversation noise.

Knowledge is populated by scraper skills:

- `elixir_source_scraper` — Elixir stdlib source from GitHub
- `erlang_docs_scraper` — Erlang/OTP docs from GitHub
- `lyse_scraper` — Learn You Some Erlang chapters
- `skill_source_indexer` — existing skill code patterns

## Async Embedding

When data is stored, the row is inserted immediately with a nil embedding. A background task under `TaskSupervisor` generates the vector via `LLM.embed/2` and updates the row with the vector plus metadata (`embedding_model`, `embedding_dim`, `embedded_at`). This keeps skill execution non-blocking.

```elixir
# Store returns immediately
{:ok, entry} = AlexClaw.Memory.store(:news_item, content, source: url)
# Embedding is generated asynchronously in the background
```

## Semantic Chunking

Content longer than 2000 characters is automatically split into semantically meaningful chunks via `AlexClaw.RAG.Chunker`:

1. **Markdown headers** (`##`, `###`) — split on heading boundaries
2. **Function definitions** (`def`, `defp`, `defmodule`) — split on code boundaries
3. **Paragraphs** (double newlines) — split on paragraph breaks
4. **Sentences** — last resort fallback

Chunks overlap by ~200 characters to preserve context at boundaries. The parent entry retains the full content (for display) but is not embedded. Only child chunks get embeddings.

## Hybrid Search

`Memory.search/2` and `Knowledge.search/2` run both search strategies:

1. **Vector similarity** — cosine distance against the query's embedding
2. **Keyword matching** — ILIKE query against content

Results are merged, deduplicated by ID, and chunk-deduplicated (multiple chunks from the same parent collapse to the best match). Falls back to keyword-only when no embedding provider is available.

### Search Options

| Option | Default | Description |
|---|---|---|
| `:limit` | 10 | Maximum results |
| `:kind` | nil | Filter by entry kind |
| `:min_score` | nil | Minimum cosine similarity (0.0–1.0). Filters in SQL via `1 - (embedding <=> ?)` |
| `:rewrite` | false | Enable query rewriting — generates 2-3 semantic variants via light LLM, embeds each, merges results |

## Query Rewriting

When `:rewrite` is enabled, `AlexClaw.RAG.QueryRewriter` calls a light-tier LLM to expand the query into 2-3 semantic variants with different terminology. Each variant is embedded and searched separately, results merged. An ETS cache (5-minute TTL) prevents redundant LLM calls for repeated queries.

## Relevance Grading

The `:min_score` option filters vector results directly in SQL. Only entries with `1 - cosine_distance >= min_score` are returned. This prevents low-relevance results from reaching the LLM and causing hallucination.

## Fallback Routing

`AlexClaw.RAG.Fallback.search_with_fallback/2` searches both Memory and Knowledge with rewriting and grading enabled, then resolves:

- **Results found** → returns formatted context
- **No results** → returns `{:no_context, :no_context}` — the caller omits the context section entirely

The Research skill uses this for cross-store RAG. Other skills search individual stores directly.

## Embedding Metadata & Staleness Detection

Each entry tracks which model generated its embedding. `stale_embedding_count/1` compares each entry's `embedding_model` against the current configured model and counts mismatches. The Services page shows a stale count when models differ.

## Deduplication

Both stores deduplicate by source URL via `exists?/1`. RSS items with the same link are not stored twice.

## Re-embedding

When switching embedding models, use `reembed_all/1` to batch-process entries with nil embeddings:

```elixir
AlexClaw.Memory.reembed_all(batch_size: 20, max_concurrency: 2)
AlexClaw.Knowledge.reembed_all(batch_size: 20, max_concurrency: 2)
```

## MCP Access

Both stores are accessible via MCP resources:

- `alexclaw://memory/{id}` — browse, read, or search memory entries
- `alexclaw://knowledge/{id}` — browse, read, or search knowledge entries

See [MCP Resources](../mcp/resources.md) for details.
