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
5. After the tier's providers, try the `local` tier

A provider hands the call to the next candidate only on a transient failure:
a timeout, a refused connection or a 5xx answer. Any other failure is the
answer. A 4xx is about the request itself — sent elsewhere it would be refused
again or, worse, taken on by a larger model. A provider named explicitly is
the only one tried.

### Context window

A prompt is measured against the provider's context window before it is sent,
and refused with `{:prompt_too_large, [%{provider, window, prompt_tokens}]}`
when it does not fit. It is not handed to another provider. The window is
`context_window` in the provider's options when set; otherwise `num_ctx` for
Ollama (Ollama's default, 4096, without it), the loaded model's context as
LM Studio reports it for a local OpenAI-compatible server, and the published
window for Gemini and Anthropic. Callers that can trim their prompt —
Forge's knowledge-base context — use `LLM.complete_fitted/2`, which builds the
prompt for the provider's budget.

### Timeouts

A call to a `local`-tier provider is abandoned after
`llm.local_timeout_seconds` (default 240) and counts as a transient failure.
A local model shares the host's memory and GPU; a call it cannot finish is not
left running. Other providers wait up to 10 minutes.

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

## Test seam

`AlexClaw.LLM` is a facade. The work happens in `AlexClaw.LLM.Real`, selected at
runtime through `Application.get_env(:alex_claw, :llm_impl)` and declared by
`AlexClaw.LLM.Behaviour`. Tests substitute a mock at that seam, so a test can
assert which tier and provider a skill asked for without a network call, and
without the skill knowing it is being tested.

`AlexClaw.LLM.Client` holds the per-provider HTTP details;
`AlexClaw.LLM.ProviderSeeder` writes the default provider rows on first boot.

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

A deployment with no cloud API keys is supported. Enable a local provider (Ollama or LM Studio) and every tier reaches it. Zero external API calls.
