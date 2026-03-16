# AlexClaw Architecture

A BEAM-native personal autonomous AI agent built on Elixir/OTP.

---

## Overview

AlexClaw monitors the world (RSS feeds, web sources, GitHub repositories, APIs), accumulates knowledge in PostgreSQL, executes workflows autonomously on schedule, and communicates with its owner via Telegram. Every task is routed to the cheapest available LLM that satisfies the required reasoning tier — including fully local models.

**Design principles:**
- **BEAM-native** — supervision, concurrency, and fault tolerance are the runtime, not bolted on
- **Single-user** — one operator, one codebase, fully auditable. Not a platform
- **Cost-aware** — multi-model LLM router maximizes free tiers across providers
- **Runtime-configurable** — all settings live in PostgreSQL, cached in ETS, editable via admin UI without restart

---

## Supervision Tree

```
AlexClaw.Application (one_for_one)
  ├── AlexClaw.Repo                    # PostgreSQL connection pool (Ecto)
  ├── Phoenix.PubSub                   # Config change broadcast
  ├── AlexClaw.LLM.UsageTracker       # ETS owner for LLM call counters + DB persistence
  ├── AlexClaw.Config.Loader          # Seeds config from env → DB, loads into ETS cache
  ├── AlexClaw.RateLimiter.Server     # ETS owner for login rate limiting + periodic purge
  ├── AlexClaw.SkillSupervisor        # DynamicSupervisor — spawns skill worker processes
  ├── AlexClaw.Scheduler              # Quantum cron scheduler
  ├── AlexClaw.Workflows.SchedulerSync # Syncs DB workflow schedules into Quantum jobs
  ├── AlexClaw.Gateway                # Telegram long-polling bot
  └── AlexClawWeb.Endpoint            # Phoenix HTTP server (LiveView admin UI)
```

---

## Core Components

### Gateway — `AlexClaw.Gateway`

GenServer that long-polls the Telegram Bot API. Normalizes inbound updates into `%Message{}` structs and passes them to the Dispatcher. Outbound messages go through `Gateway.send_message/2` which calls the Telegram `sendMessage` API with Markdown parsing.

### Dispatcher — `AlexClaw.Dispatcher`

Deterministic pattern-matching router. No LLM involved in routing — zero token cost for dispatch. Maps Telegram commands to skills:

```
/ping           → pong
/status         → system stats (uptime, memory, active skills)
/skills         → list from SkillRegistry
/llm            → provider status
/workflows      → list all workflows with status/schedule
/run <id|name>  → execute a workflow on demand
/research <q>   → Research skill
/search <q>     → WebSearch skill
/web <url> [q]  → WebBrowse skill
/github pr ...  → GitHubSecurityReview skill
/github commit  → GitHubSecurityReview skill
/help           → command list
<free text>     → Conversational skill (LLM fallback)
```

### Skill Supervisor — `AlexClaw.SkillSupervisor`

DynamicSupervisor. Each skill execution runs as an isolated OTP process. Crashes are contained — a failed RSS fetch does not affect a concurrent research query.

### LLM Router — `AlexClaw.LLM`

Every LLM call declares a tier requirement. The router selects the cheapest available model, tracks daily usage in ETS against configurable limits, and falls back automatically.

```
light:  gemini_flash → haiku → lm_studio → ollama
medium: gemini_pro → sonnet → lm_studio → ollama
heavy:  opus → lm_studio → ollama
local:  lm_studio → ollama
```

Built-in providers: Gemini Flash, Gemini Pro, Claude Haiku, Claude Sonnet, Claude Opus, Ollama, LM Studio.

Custom providers can be added via the admin UI — stored in PostgreSQL with type (`openai_compatible`, `ollama`, `gemini`, `anthropic`, `custom`), tier assignment, and optional daily limits. Custom providers are tried as fallback after built-in models for their tier.

Usage counters are keyed by `{provider, Date.utc_today()}` in ETS and persisted to the database so counts survive restarts.

### Memory — `AlexClaw.Memory`

PostgreSQL + pgvector knowledge store. Schema:

- `kind` — `fact`, `summary`, `news_item`, `conversation`, `security_review`
- `content` — the stored text
- `source` — URL, feed name, skill name
- `embedding` — pgvector column (currently returns nil — embedding integration is stub)
- `metadata` — JSONB
- `expires_at` — optional TTL

Search falls back to keyword (ILIKE) when no embeddings are available. Deduplication by URL/content via `Memory.exists?/1`.

### Identity — `AlexClaw.Identity`

Builds the system prompt injected into every LLM call. All strings come from `AlexClaw.Config` — zero hardcoded persona text. Supports per-skill context fragments via config keys like `prompts.context.rss_collector`.

### Config — `AlexClaw.Config`

Runtime configuration system. On boot, `Config.Loader` seeds default values from environment variables into PostgreSQL. After that, all changes are made through the admin UI. Values are cached in an ETS table for fast reads. Changes are broadcast via Phoenix PubSub so all processes see updates immediately. No restart required.

Categories: `identity`, `llm`, `telegram`, `rss`, `github`, `auth`, `prompts`.

### Rate Limiter — `AlexClaw.RateLimiter`

ETS-based login rate limiting. Tracks failed attempts per IP. After a configurable number of failures (default 5), blocks the IP for a configurable duration (default 15 minutes). A GenServer runs a periodic purge cycle to clean expired entries. All limits are adjustable at runtime via Config UI.

---

## Workflow Engine

Workflows are multi-step pipelines stored in PostgreSQL. Each step specifies a skill name, a config JSON (overrides global Config defaults), and an order. The executor runs steps sequentially, passing each step's output as input to the next.

Key architecture decision: **step config overrides global config**. A workflow can target a different GitHub repo, use a different Telegram bot, or route to a specific LLM provider — all via step-level config JSON. This means skills like `github_security_review` can run against different repos with different tokens in different workflows.

Workflows can be:
- Triggered on schedule via cron expressions (synced to Quantum by `SchedulerSync`)
- Run on demand via Telegram (`/run <id or name>`)
- Run from the admin UI

Run history with step-level results is stored in the database and visible in the admin UI.

---

## Skills

Skills are Elixir modules registered in `AlexClaw.Workflows.SkillRegistry`. Each skill implements `run/1` (takes a config map, returns `{:ok, result}` or `{:error, reason}`) and optionally `description/0` for runtime introspection.

| Skill | Module | Tier | Description |
|---|---|---|---|
| `rss_collector` | `AlexClaw.Skills.RSSCollector` | light | Fetch RSS feeds, score relevance via LLM, notify |
| `web_search` | `AlexClaw.Skills.WebSearch` | medium | Search the web and synthesize answers |
| `web_browse` | `AlexClaw.Skills.WebBrowse` | medium | Fetch and summarize a URL |
| `research` | `AlexClaw.Skills.Research` | medium | Deep research with memory context |
| `conversational` | `AlexClaw.Skills.Conversational` | light | Free-text conversation with identity/memory |
| `telegram_notify` | `AlexClaw.Skills.TelegramNotify` | — | Send a Telegram message (workflow glue step) |
| `llm_transform` | `AlexClaw.Workflows.LLMTransform` | configurable | Run a prompt template through the LLM |
| `api_request` | `AlexClaw.Skills.ApiRequest` | — | Make an authenticated HTTP request |
| `github_security_review` | `AlexClaw.Skills.GitHubSecurityReview` | medium | Fetch PR/commit diff, run LLM security analysis |

---

## GitHub Security Review

Reviews pull requests and commits for security issues:

- Fetches diff via GitHub API (supports fine-grained tokens per workflow)
- Truncates diff at 24KB for local model compatibility
- LLM produces structured output: RISK LEVEL, FINDINGS, SUMMARY, RECOMMENDATION
- Results stored in Memory (kind: `security_review`)
- Webhook endpoint at `/webhooks/github` with HMAC-SHA256 signature verification
- Telegram trigger: `/github pr owner/repo 42` or `/github commit owner/repo <sha>`

---

## Web Interface

Phoenix LiveView admin UI. Session-based authentication — all routes except `/login` require an authenticated session. No JavaScript hooks — fully server-rendered.

| Page | Description |
|---|---|
| Dashboard | System status, recent activity |
| Workflows | Create/edit/run pipelines, view run history with step results |
| Skills | Dynamic list from SkillRegistry with descriptions |
| Scheduler | Cron jobs and scheduled workflows |
| LLM | Provider status, usage, custom provider management |
| Feeds | RSS feed management |
| Resources | Shared resources for workflows |
| Memory | Browse and search stored knowledge |
| Database | Schema browser and backup download |
| Config | Runtime configuration editor (collapsible categories) |

---

## Project Structure

```
lib/
  alex_claw/
    config/
      loader.ex              # Seed env → DB, load into ETS
      seeder.ex              # Default config definitions
      setting.ex             # Ecto schema for config entries
    llm/
      provider.ex            # Custom provider schema
      usage_tracker.ex       # ETS owner + DB persistence GenServer
    memory/
      entry.ex               # Memory entry Ecto schema
    skills/
      api_request.ex
      conversational.ex
      github_security_review.ex
      research.ex
      rss_collector.ex
      telegram_notify.ex
      web_browse.ex
      web_search.ex
    workflows/
      executor.ex            # Runs workflow steps sequentially
      llm_transform.ex       # Prompt template skill for workflows
      scheduler_sync.ex      # Syncs DB schedules → Quantum jobs
      skill_registry.ex      # Maps skill names → modules
      workflow.ex            # Workflow Ecto schema
      workflow_resource.ex   # Shared resource Ecto schema
      workflow_run.ex        # Workflow run Ecto schema
      workflow_step.ex       # Workflow step Ecto schema
    application.ex           # Supervision tree
    dispatcher.ex            # Telegram command routing
    gateway.ex               # Telegram bot (long-polling)
    identity.ex              # Persona / system prompt builder
    llm.ex                   # Multi-model LLM router
    memory.ex                # Knowledge store API
    message.ex               # Internal message struct
    rate_limiter.ex          # ETS-based login rate limiting
    rate_limiter/server.ex   # GenServer for ETS ownership + purge
    scheduler.ex             # Quantum cron scheduler
    skill.ex                 # Skill behaviour definition
  alex_claw_web/
    controllers/
      auth_controller.ex     # Login/logout with rate limiting
      database_controller.ex # Schema browser, backup download
      github_webhook_controller.ex  # GitHub webhook receiver
    live/admin_live/         # LiveView pages (dashboard, workflows, config, etc.)
    plugs/
      rate_limit.ex          # Plug for POST /login rate limiting
      raw_body_reader.ex     # Caches raw body for webhook signature verification
      require_auth.ex        # Session-based auth guard
    router.ex
priv/repo/
  migrations/                # All DB migrations
  seeds/                     # Example workflow seeds
config/
  config.exs
  runtime.exs                # Reads env vars for DB, secret key, Telegram token
```

---

## Dependencies

```elixir
{:phoenix, "~> 1.7"}
{:phoenix_live_view, "~> 1.0"}
{:bandit, "~> 1.6"}           # HTTP server
{:ecto_sql, "~> 3.11"}
{:postgrex, ">= 0.0.0"}
{:pgvector, "~> 0.3"}         # pgvector Ecto type
{:req, "~> 0.5"}              # HTTP client (feeds, APIs, LLM providers)
{:sweet_xml, "~> 0.7"}        # RSS/XML parsing
{:floki, "~> 0.37"}           # HTML parsing (web browse/search)
{:quantum, "~> 3.5"}          # Cron scheduler
{:jason, "~> 1.4"}            # JSON
{:telemetry_metrics, "~> 1.0"}
{:telemetry_poller, "~> 1.0"}
```

---

## Data Flow Examples

### Scheduled Workflow (RSS Digest)

```
Quantum fires cron job
  → SchedulerSync dispatches → Workflows.Executor.run(workflow_id)
    → Step 1: rss_collector skill
      ├── Fetch feeds (Req + SweetXml)
      ├── Deduplicate via Memory.exists?
      ├── Score relevance via LLM (tier: light)
      ├── Filter by score threshold
      └── Store in Memory
    → Step 2: telegram_notify skill
      └── Send digest to Telegram
```

### On-Demand Command

```
User sends "/research Elixir 1.19 compilation" via Telegram
  → Gateway normalizes → %Message{}
    → Dispatcher pattern matches → Research.handle("Elixir 1.19 compilation")
      ├── Memory.search(query) — recent context
      ├── LLM.complete(prompt, tier: :medium)
      ├── Memory.store(:summary, result)
      └── Gateway.send_message(response)
```

### GitHub Webhook

```
GitHub sends push event → POST /webhooks/github
  → RawBodyReader caches body
    → WebhookController verifies HMAC-SHA256 signature
      → GitHubSecurityReview.review_commit(repo, sha)
        ├── Fetch diff via GitHub API
        ├── Truncate to 24KB
        ├── LLM.complete(analysis_prompt, tier: :medium)
        ├── Memory.store(:security_review, report)
        └── Gateway.send_message(report)
```

---

## Security

- Session-based authentication on all admin routes
- ETS-based login rate limiting (configurable attempts and block duration)
- HMAC-SHA256 webhook signature verification with timing-safe comparison
- API keys stored in PostgreSQL (plaintext — restrict DB access at network level)
- Sensitive values masked in admin UI
- See [SECURITY.md](SECURITY.md) for full policy and deployment hardening
