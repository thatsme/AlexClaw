# LLM Router

Every LLM call in AlexClaw declares a **tier requirement**. The router selects the cheapest available provider that satisfies the tier, tracks usage, and falls back gracefully.

## Tier System

| Tier | Default Providers | Typical Use |
|---|---|---|
| `light` | Gemini Flash, Claude Haiku | RSS scoring, classification, simple tasks |
| `medium` | Gemini Pro, Claude Sonnet | Summarization, research, security review |
| `heavy` | Claude Opus | Deep reasoning (explicit only) |
| `local` | LM Studio, Ollama | Privacy-sensitive, offline, zero cost |

## Provider Selection

1. Query `llm_providers` table for enabled providers matching the requested tier
2. Order by `priority` (lower number = preferred)
3. Check daily usage limits (if configured)
4. Select first available provider
5. If no provider available for the tier, fall back to `local` tier

```elixir
# A skill requests a tier, not a specific model
AlexClaw.LLM.call(prompt, tier: :medium)
```

## Provider Types

| Type | Examples | API Format |
|---|---|---|
| `gemini` | Gemini Flash, Gemini Pro | Google AI Studio API |
| `anthropic` | Claude Haiku, Sonnet, Opus | Anthropic Messages API |
| `openai_compatible` | LM Studio, any OpenAI-compatible | OpenAI Chat Completions |
| `ollama` | Local Ollama models | Ollama `/api/chat` (messages format) |

## Provider Options

Each provider row has an `options` JSONB column for provider-specific inference parameters (e.g., `num_ctx`, `temperature`, `top_p`). These are sent with every request to that provider and can be edited from **Admin > LLM Providers** via a dynamic options form that adapts to the provider type. For OpenAI-compatible providers, the client falls back to `reasoning_content` when `content` is empty (Qwen3 thinking mode). Qwen3 models also expose a thinking toggle in the Admin UI.

## Usage Tracking

- Counters are keyed by `{provider_id, date}` in ETS for fast reads
- Persisted to `llm_usage` table so counts survive restarts
- Visible in **Admin > LLM Providers** and the `/metrics` endpoint

## Embedding Support

`LLM.embed/2` generates 768-dimension vectors for semantic search:

- Provider resolution is separate from the completion tier system
- Configured via `embedding.provider` config, or auto-detected: Gemini → Ollama → OpenAI-compatible
- Supports Gemini `text-embedding-004` (free tier), Ollama `/api/embed`, and OpenAI `/v1/embeddings`
- Concurrent embedding requests are throttled by `EmbedThrottle` (GenServer limiter)
- Embedding calls are tracked in the same usage counters

## Workflow Integration

LLM provider selection can be configured at three levels (most specific wins):

1. **Step-level** — `llm_tier` and `llm_model` fields on the workflow step
2. **Workflow-level** — `default_provider` field on the workflow
3. **Global** — tier-based fallback chain

## Fully Local Deployment

A deployment with no cloud API keys is supported. Enable a local provider (Ollama or LM Studio) and all tiers fall back to it. Zero external API calls.
