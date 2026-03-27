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

## Knowledge — `AlexClaw.Knowledge`

Stores documentation, guides, and reference material. Same schema as Memory but in a separate table (`knowledge_entries`), isolated from news and conversation noise.

Knowledge is populated by scraper skills:

- `elixir_source_scraper` — Elixir stdlib source from GitHub
- `erlang_docs_scraper` — Erlang/OTP docs from GitHub
- `lyse_scraper` — Learn You Some Erlang chapters
- `skill_source_indexer` — existing skill code patterns

## Async Embedding

When data is stored, the row is inserted immediately with a nil embedding. A background task under `TaskSupervisor` generates the vector via `LLM.embed/2` and updates the row. This keeps skill execution non-blocking.

```elixir
# Store returns immediately
{:ok, entry} = AlexClaw.Memory.store(:news_item, content, source: url)
# Embedding is generated asynchronously in the background
```

## Hybrid Search

`Memory.search/2` and `Knowledge.search/2` run both search strategies in parallel:

1. **Vector similarity** — cosine distance against the query's embedding
2. **Keyword matching** — ILIKE query against content

Results are merged with vector results prioritized, keyword results filling gaps. Falls back to keyword-only when no embedding provider is available.

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
