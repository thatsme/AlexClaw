# AlexClaw Architecture

A BEAM-native personal autonomous AI agent built on Elixir/OTP.

---

## Overview

AlexClaw monitors the world (RSS feeds, web sources, GitHub repositories, Google services, APIs), accumulates knowledge in PostgreSQL, executes workflows autonomously on schedule, and communicates with its owner via Telegram. Every task is routed to the cheapest available LLM that satisfies the required reasoning tier — including fully local models.

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
  ├── Task.Supervisor (AlexClaw.TaskSupervisor)  # Supervised fire-and-forget tasks
  ├── AlexClaw.LLM.UsageTracker       # ETS owner for LLM call counters + DB persistence
  ├── AlexClaw.Config.Loader          # Seeds config from env → DB, loads into ETS cache
  ├── AlexClaw.LogBuffer              # In-memory ring buffer for recent logs (500 entries)
  ├── AlexClaw.Google.TokenManager    # Google OAuth2 token lifecycle (ETS cache + auto-refresh)
  ├── AlexClaw.RateLimiter.Server     # ETS owner for login rate limiting + periodic purge
  ├── Registry (CircuitBreakerRegistry)  # Process registry for per-skill circuit breakers
  ├── AlexClaw.Skills.CircuitBreakerSupervisor  # DynamicSupervisor — per-skill circuit breakers
  ├── AlexClaw.SkillSupervisor        # DynamicSupervisor — spawns skill worker processes
  ├── AlexClaw.MCP.Server            # MCP server (Streamable HTTP via anubis_mcp)
  ├── AlexClaw.Cluster.Manager       # Node registration, discovery, remote workflow triggers
  ├── AlexClaw.Scheduler              # Quantum cron scheduler
  ├── AlexClaw.Workflows.SchedulerSync # Syncs DB workflow schedules into Quantum jobs
  ├── AlexClaw.Gateway.Telegram       # Telegram long-polling bot
  ├── AlexClaw.Gateway.Discord        # Discord bot via Nostrum (conditional — only if token set)
  └── AlexClawWeb.Endpoint            # Phoenix HTTP server (LiveView admin UI)
```

All async work (workflow execution, GitHub reviews, background tasks) runs under `AlexClaw.TaskSupervisor` — crashes are reported and supervised, not silently lost.

---

## Core Components

### Gateway — Multi-Transport Architecture

The gateway layer supports multiple messaging transports via a behaviour pattern:

- **`AlexClaw.Gateway.Behaviour`** — defines the contract: `send_message/2`, `send_html/2`, `send_photo/3`, `name/0`, `configured?/0`
- **`AlexClaw.Gateway.Telegram`** — GenServer that long-polls the Telegram Bot API. Normalizes inbound updates into `%Message{gateway: :telegram}` structs.
- **`AlexClaw.Gateway.Discord`** — Nostrum consumer that receives Discord MESSAGE_CREATE events. Normalizes into `%Message{gateway: :discord}`. Uses Nostrum's REST API for sending. Only started when `DISCORD_BOT_TOKEN` is set at boot.
- **`AlexClaw.Gateway.Router`** — resolves the correct gateway from `opts[:gateway]` and delegates. Falls back to the first configured gateway (Telegram preferred). Provides `broadcast/2` for system-level notifications to all active gateways.
- **`AlexClaw.Gateway`** — thin facade with `defdelegate` to Router for backward compatibility. All existing code calls this module unchanged.

The Dispatcher threads `gateway: msg.gateway` through all send calls, ensuring responses route back to the originating transport.

### Dispatcher — `AlexClaw.Dispatcher`

Deterministic pattern-matching router. No LLM involved in routing — zero token cost for dispatch. Maps commands to skills:

```
/ping              → pong
/status            → system stats (uptime, memory, active skills)
/skills            → list from SkillRegistry
/skill             → skill management is Admin UI only (2FA enforced)
/llm               → provider status and usage
/workflows         → list all workflows with status/schedule
/run <id|name>     → execute a workflow on demand (supports 2FA gating)
/research <q>      → Research skill
/research --tier T → Save default tier for research (persisted to DB)
/search <q>        → WebSearch skill
/search --tier T   → Save default tier for web search (persisted to DB)
/web <url> [q]     → WebBrowse skill
/web --tier T      → Save default tier for web browse (persisted to DB)
/github pr <r> [n] → GitHubSecurityReview — review PR
/github commit <r> <sha> → GitHubSecurityReview — review commit
/coder <goal>      → Coder — generate a dynamic skill from description (local LLM)
/shell <command>   → Shell — execute whitelisted OS command (2FA-gated)
/rate <run_id>     → View/rate workflow step outcomes (+/- or up/down)
/record <url>      → WebAutomation — start browser recording
/record stop <sid> → WebAutomation — stop recording, save as resource
/replay <id>       → WebAutomation — replay a saved automation
/automate <url>    → WebAutomation — headless scrape/screenshot
/tasks             → Google Tasks — list tasks
/task add <title>  → Google Tasks — create a task
/tasklists         → Google Tasks — list task lists
/connect google    → Google OAuth — initiate authorization flow
/setup 2fa         → TOTP — generate secret and QR code
/confirm 2fa <code>→ TOTP — confirm 2FA setup
/disable 2fa       → TOTP — disable 2FA
/help              → command list
<free text>        → Conversational skill (LLM fallback)
```

### Skill Supervisor — `AlexClaw.SkillSupervisor`

DynamicSupervisor. Each skill execution runs as an isolated OTP process. Crashes are contained — a failed RSS fetch does not affect a concurrent research query.

### LLM Router — `AlexClaw.LLM`

Every LLM call declares a tier requirement. The router queries the `llm_providers` table for enabled providers matching that tier, ordered by `priority` (lower = preferred). If no provider is available for the requested tier, it falls back to the `local` tier.

All providers — cloud and local — are stored in PostgreSQL with type (`openai_compatible`, `ollama`, `gemini`, `anthropic`, `custom`), tier assignment, priority, and optional daily limits. Default providers (Gemini Flash/Pro, Claude Haiku/Sonnet/Opus, Ollama, LM Studio) are seeded on first boot by `ProviderSeeder`. Additional providers can be added, removed, or reconfigured from the admin UI at runtime.

Usage counters are keyed by `{provider_id, Date.utc_today()}` in ETS and persisted to the `llm_usage` table so counts survive restarts.

**Embedding support:** `LLM.embed/2` generates 768-dimension vectors for semantic memory search. Provider resolution is separate from the completion tier system — configured via `embedding.provider` (or auto-detected: Gemini → Ollama → OpenAI-compatible). Each provider type has a dedicated response parser (Gemini `embedContent`, Ollama `/api/embed`, OpenAI `/v1/embeddings`). Embedding calls are tracked in the same usage counters as completions.

### Memory — `AlexClaw.Memory`

PostgreSQL + pgvector knowledge store. Schema:

- `kind` — `fact`, `summary`, `news_item`, `conversation`, `security_review`, `web_search`, `web_page`
- `content` — the stored text
- `source` — URL, feed name, skill name
- `embedding` — pgvector column (768 dimensions, HNSW index with cosine distance)
- `metadata` — JSONB
- `expires_at` — optional TTL

**Async embedding:** `Memory.store/3` inserts the row immediately with a nil embedding, then fires a background task under `TaskSupervisor` to generate the vector via `LLM.embed/2` and update the row. This keeps skill execution non-blocking.

**Hybrid search:** `Memory.search/2` runs both vector similarity and keyword (ILIKE) queries in parallel, merges results with `Enum.uniq_by/2` (vector results first), and returns the top N. Falls back to keyword-only when no embedding provider is available.

**Embedding providers:** `LLM.embed/2` resolves a provider via `embedding.provider` config (or auto-detects: Gemini → Ollama → OpenAI-compatible). Supports Gemini `text-embedding-004` (free tier), Ollama `/api/embed`, and any OpenAI-compatible `/v1/embeddings` endpoint.

**Re-embedding:** `Memory.reembed_all/1` batch-processes all entries with nil embeddings in the background using `Task.async_stream` with configurable concurrency. Used when switching embedding models.

Deduplication by URL/content via `Memory.exists?/1`.

### Identity — `AlexClaw.Identity`

Builds the system prompt injected into every LLM call. All strings come from `AlexClaw.Config` — zero hardcoded persona text. Supports per-skill context fragments via config keys like `prompts.context.rss_collector`.

### Config — `AlexClaw.Config`

Runtime configuration system. On boot, `Config.Loader` seeds default values from environment variables into PostgreSQL. After that, all changes are made through the admin UI. Values are cached in an ETS table for fast reads. Changes are broadcast via Phoenix PubSub so all processes see updates immediately. No restart required.

Sensitive values (API keys, tokens, OAuth secrets) are encrypted at the application level using AES-256-GCM before storage. The encryption key is derived from `SECRET_KEY_BASE` via HKDF-SHA256 and cached in `:persistent_term`. Each value gets a unique random IV. On boot, `EncryptExisting` idempotently encrypts any plaintext sensitive values, then `Config.init()` reloads ETS with decrypted values. The `sensitive` boolean flag on each setting controls encryption behavior.

Categories: `identity`, `llm`, `embedding`, `telegram`, `skills`, `github`, `google`, `auth`, `prompts`, `web_automator`, `shell`, `coder`.

### LogBuffer — `AlexClaw.LogBuffer`

In-memory ring buffer (500 entries max) attached to the Erlang Logger. Classifies log entries by severity (`critical`, `high`, `moderate`, `low`, `circuit_breaker`) using pattern matching on log level and message content. Circuit breaker events are identified by the `[CircuitBreaker]` prefix. Filters out verbose OTP/Ecto noise. Exposes `recent/1` for filtered retrieval and `counts/0` for severity aggregates. Powers the real-time log viewer in the admin UI.

### Circuit Breaker — `AlexClaw.Skills.CircuitBreaker`

Per-skill OTP circuit breaker. One GenServer per skill, managed by `CircuitBreakerSupervisor` (DynamicSupervisor). Uses ETS (`:circuit_breakers`) for lock-free state reads on the hot path and `Process.send_after` for reset timers. Zero external dependencies.

**States:** `:closed` (normal) → `:open` (failing, calls rejected) → `:half_open` (testing with one probe call)

**Behavior:**
- Skill fails 3 consecutive times → circuit opens → Telegram notification
- Circuit open → `{:error, :circuit_open}` returned instantly, skill not called
- After 5 minutes → half-open → one test call allowed
- Test succeeds → circuit closes (recovered) → Telegram notification
- Test fails → circuit reopens → wait again

**Integration:** `CircuitBreaker.call/2` wraps skill execution transparently in the Executor. Skills have zero awareness of the breaker — no changes to `run/1` signatures or args.

**Workflow resilience:** Per-step config controls behavior when a circuit is open or skill is missing:
- `on_circuit_open`: `"halt"` (default) | `"skip"` (pass input through) | `"fallback"` (route to alternative skill)
- `on_missing_skill`: `"halt"` (default) | `"skip"` (pass input through)
- `fallback_skill`: name of the alternative skill (used with `"fallback"`)

These are configurable per step via the workflow editor UI (dropdowns, not JSON).

**Dynamic skill lifecycle:** Subscribes to PubSub `"skills:registry"`. When a dynamic skill is unloaded, its breaker is cleaned up. When reloaded, the breaker resets (fresh code = fresh circuit).

**Observability:** Circuit breaker events are classified as `:circuit_breaker` severity in `LogBuffer` (matched by `[CircuitBreaker]` prefix). The Logs page has a dedicated "Circuit Breaker" filter with blue badge.

### Rate Limiter — `AlexClaw.RateLimiter`

ETS-based login rate limiting. Tracks failed attempts per IP. After a configurable number of failures (default 5), blocks the IP for a configurable duration (default 15 minutes). A GenServer runs a periodic purge cycle to clean expired entries. All limits are adjustable at runtime via Config UI.

---

## Authentication & Security

### Admin UI Authentication

Session-based cookie authentication. All routes except `/login` require an authenticated session via the `RequireAuth` plug. Password is set via the `ADMIN_PASSWORD` environment variable. Login rate limiting is enforced by the `RateLimit` plug on `POST /login`.

### 2FA / TOTP — `AlexClaw.Auth.TOTP`

Optional TOTP-based two-factor authentication for sensitive operations. Setup flow via Telegram:

1. `/setup 2fa` — generates secret, sends QR code image and manual key
2. User scans QR with Google Authenticator (or compatible app)
3. `/confirm 2fa <code>` — verifies first code, enables 2FA

Once enabled, workflows with `requires_2fa: true` in their metadata trigger a challenge before execution. Challenges expire after 2 minutes. Secrets and state are stored in ETS with the TOTP secret persisted in Config.

### GitHub Webhooks

`POST /webhooks/github` with HMAC-SHA256 signature verification. The `CachingBodyReader` plug caches the raw request body before JSON parsing so the HMAC is verified against the original payload, not re-serialized JSON. Push events on watched branches trigger automatic security reviews.

### Agent Authorization Layer

Composable authorization system for skill execution, built in three layers:

**Context-Aware Permission Checks** — `AlexClaw.Auth.PolicyEngine`
Every `SkillAPI` call builds an `AuthContext` (caller, type, permission, chain depth, workflow run ID) and evaluates it through the `PolicyEngine`. Core skills bypass all checks. Dynamic skills are checked against declared permissions, capability tokens, and active policy rules. Chain depth limited to 3 to prevent infinite skill→skill recursion.

**Capability Tokens** — `AlexClaw.Auth.CapabilityToken`
Macaroon-style HMAC-signed tokens. When a workflow runs, each step gets a token scoped to the skill's declared permissions. Cross-skill invocation via `run_skill/3` attenuates the token — child skills can only receive a subset. Signing key derived from `SECRET_KEY_BASE` via HKDF-SHA256.

**Process Isolation** — `AlexClaw.Auth.SafeExecutor`
Dynamic skills run in a spawned, monitored process. The capability token is set in the child's process dictionary, isolating it from the caller. Core skills run in-process (no overhead).

**Policy Rules** — `AlexClaw.Auth.Policy` (PostgreSQL, cached in ETS)
Configurable rules evaluated by PolicyEngine: `rate_limit`, `time_window`, `chain_restriction`, `permission_override`. Managed via Admin > Policies.

**Audit Logging** — `AlexClaw.Auth.AuditLog`
All authorization denials persisted to `auth_audit_log` table. Viewable from Admin > Policies > Audit Log. Auto-pruned after 30 days.

---

## Google Integration

### OAuth Flow — `AlexClaw.Google.OAuth`

1. User sends `/connect google` via Telegram
2. Gateway generates an auth URL with a random state token linked to their chat_id (expires in 10 minutes)
3. User taps the link, authorizes in Google's consent screen
4. Google redirects to `/auth/google/callback` with code + state
5. `OAuthCallbackController` exchanges the code for tokens
6. Refresh token stored in Config, access token cached in `Google.TokenManager`

Scopes: `calendar.readonly`, `tasks`.

### Token Manager — `AlexClaw.Google.TokenManager`

GenServer that caches the current Google access token in ETS. Automatically refreshes the token before expiry (5-minute margin). All Google API calls go through `TokenManager.get_token/0` which returns `{:ok, token}` or `{:error, reason}`.

---

## Workflow Engine

Workflows are **linear pipelines** with conditional branching. The executor walks the step graph sequentially — each step has exactly one successor per branch. There is no fan-out (one step broadcasting to multiple parallel successors). A step's output feeds into the next step's input, forming a single execution path per run.

**Current limitation:** A step cannot fork into multiple parallel paths. For example, you cannot wire `rss_collector` to simultaneously feed `telegram_notify` AND `llm_transform`. The workaround is chaining notify steps sequentially — notify skills pass through their input unchanged, so downstream steps still receive the original data.

### Conditional Branching

Each skill declares its possible outcomes via the `routes/0` callback (e.g. `[:on_items, :on_empty, :on_error]`). Skills return a triple tuple `{:ok, result, :branch_name}` indicating which outcome occurred. The executor matches the branch against the step's routes to determine the next step. Only **one** branch is followed per step — this is conditional routing, not fan-out.

```
Step 1: Fetch RSS feeds
  → on_items: Step 2 (score items)
  → on_empty: Step 4 (send "no news today")
  → on_error: Step 5 (notify failure)
```

Steps without routes fall through to the next position (backward compatible with linear workflows). Errors without an `:on_error` route halt the workflow (backward compatible). Loop protection via visited set prevents infinite cycles.

### Step Wiring

By default, each step receives the output of the previous step as its input. The `input_from` field enables non-linear wiring — a step can pull its input from any earlier step by specifying its order number. This allows fan-in patterns where multiple processing branches converge.

### Provider Routing

LLM provider selection can be configured at three levels (most specific wins):
1. **Step-level** — `llm_tier` and `llm_model` fields on the workflow step
2. **Workflow-level** — `default_provider` field on the workflow
3. **Global** — tier-based fallback chain in the LLM router

### Execution

- **Scheduled** — cron expressions synced to Quantum by `SchedulerSync`
- **On-demand via Telegram** — `/run <id or name>` (supports 2FA gating)
- **Admin UI** — run button on workflow and scheduler pages

All workflow executions run under `AlexClaw.TaskSupervisor`. Run history with step-level results (output, duration, success/failure) is stored in the database and visible in the admin UI.

### Execution Outcome Annotation — `AlexClaw.Workflows.SkillOutcome`

Every skill execution within a workflow is recorded in the `skill_outcomes` table with timing (`duration_ms`), a truncated output snapshot (max 2KB), and metadata (branch taken, errors). Outcomes start with `result_quality: "neutral"` and can be annotated by the user via the `/rate` gateway command (`+`/`-`, `up`/`down`, or thumbs emoji). Rating can target an entire run or individual steps.

Skills can query past outcomes via `SkillAPI.skill_outcomes/3` (requires `:memory_read` permission) to inform future execution — this is the foundation for episodic memory and self-improvement loops.

### Live Run Control — `AlexClaw.Workflows.Registry`

A GenServer + ETS registry that tracks every running workflow process. Enables:

- **Active run visibility** — `list_active/0` returns all running workflows with PID, workflow name, current step, and start time
- **Cancellation** — `cancel/1` updates DB status to "cancelled", sends `Process.exit(pid, :cancelled)`, broadcasts PubSub event
- **Crash cleanup** — monitors registered PIDs; on unexpected death, marks the DB run as "failed" automatically
- **Real-time UI** — PubSub events on topic `"workflows:runs"` drive the Active Runs panel in the admin UI (step-by-step progress, cancel button, 10s linger on completion)
- **Chat commands** — `/runs` lists active workflows, `/cancel <run_id>` stops a running workflow

Events broadcast: `workflow_run_started`, `workflow_step_started`, `workflow_step_completed`, `workflow_run_completed`, `workflow_run_failed`, `workflow_run_cancelled`.

### Resilience

Each workflow step has per-step resilience controls configured via the workflow editor UI:
- **On Circuit Open** — what to do when the skill's circuit breaker is open: halt the workflow, skip the step (pass input through to the next step), or route to a fallback skill
- **On Missing Skill** — what to do when the skill is not loaded (e.g. dynamic skill unloaded): halt or skip
- **Fallback Skill** — alternative skill to execute when "Fallback skill" is selected

The circuit breaker wraps skill execution transparently in `Executor.execute_step/5`. Skills are unaware of the breaker.

### Notifications

When a workflow contains a `telegram_notify` step, the executor sends a start notification when the workflow begins and a failure notification if any step fails before reaching the notify step.

### Multi-Node Distribution — `AlexClaw.Cluster.Manager`

AlexClaw supports multi-node BEAM clustering. Each node runs its own sequential executor — no parallel step changes. Nodes exchange workflow outputs over Erlang distribution.

**ClusterManager** is a GenServer that:
- Auto-registers itself and connecting nodes via `:net_kernel.monitor_nodes/1`
- Pings known nodes from the DB 5 seconds after boot
- Updates node status on `:nodeup`/`:nodedown` events
- Handles incoming remote workflow triggers via `receive_workflow_data/3` (called by `:rpc.call` from remote nodes)
- Validates the target workflow has `receive_from_workflow` as step 1 before allowing execution

**Cross-node workflow flow:**
1. Node A runs a workflow with a `send_to_workflow` step
2. `send_to_workflow` calls `:rpc.call(node_b, ClusterManager, :receive_workflow_data, ...)` with a 5s default timeout
3. Node B's ClusterManager validates the gate, spawns the target workflow via `Task.Supervisor`
4. The target workflow's `receive_from_workflow` step receives the data as input with `_source_node` in config

**Node assignment:** Workflows have an optional `node` field. If set, only that node's scheduler picks it up. If null, it's cluster-wide (any node can run it). The admin UI shows a "Run on" dropdown populated from connected cluster nodes.

**Gateway behavior in cluster:** Single-node mode ignores `telegram.node` and `discord.node` — gateways always start. In a cluster (connected peers detected), gateways only start on the assigned node. Setting `telegram.enabled = true` from a node's Config UI auto-assigns `telegram.node` to that node. Cross-node config changes propagate via PubSub over BEAM distribution.

**Configuration:** `NODE_NAME` (default: `alexclaw@node1.local`) and `CLUSTER_COOKIE` env vars. Long names (containing `.`) use EPMD for distribution. The naming convention is `alexclaw@nodeN.local` — same format for single-node and swarm.

---

## Skills

Skills are Elixir modules implementing the `AlexClaw.Skill` behaviour (`run/1`, optional `description/0`, `routes/0`, `permissions/0`, `version/0`, `external/0`). Skills return `{:ok, result, :branch}` for conditional routing or `{:ok, result}` for backward compatibility. Registered in `AlexClaw.Workflows.SkillRegistry` with routes and external flag stored in ETS alongside permissions.

Skills that fetch data from external sources declare `def external, do: true`. The workflow executor auto-sanitizes output from external skills through `AlexClaw.ContentSanitizer` (7-layer heuristic pipeline). Dynamic skills are AST-scanned at load time — undeclared HTTP/socket calls are rejected.

| Skill | Module | Tier | Description |
|---|---|---|---|
| `rss_collector` | `RSSCollector` | light | Fetch RSS feeds, batch-score relevance via LLM, notify |
| `web_search` | `WebSearch` | medium | Search DuckDuckGo, fetch top results, synthesize answer |
| `web_browse` | `WebBrowse` | light | Fetch and summarize a URL, optionally answer questions |
| `research` | `Research` | medium | Deep research with memory context |
| `conversational` | `Conversational` | light | Free-text conversation with identity and memory |
| `telegram_notify` | `TelegramNotify` | — | Send workflow output to Telegram (markdown → HTML) |
| `discord_notify` | `DiscordNotify` | — | Send workflow output to a Discord channel (configurable `channel_id` per step) |
| `llm_transform` | `LLMTransform` | configurable | Run a prompt template through the LLM |
| `api_request` | `ApiRequest` | — | Make an authenticated HTTP request with retries |
| `github_security_review` | `GitHubSecurityReview` | medium | Fetch PR/commit diff, run LLM security analysis |
| `google_calendar` | `GoogleCalendar` | — | Fetch upcoming events from Google Calendar |
| `google_tasks` | `GoogleTasks` | — | List and create Google Tasks |
| `db_backup` | `DbBackup` | — | PostgreSQL backup with gzip compression and rotation to host-mounted path |
| `shell` | `Shell` | — | Execute whitelisted OS commands for container introspection |
| `coder` | `Coder` | local | Autonomous skill generation from natural language goals |
| `web_automation` | `WebAutomation` | — | Browser recording and headless replay via sidecar |
| `send_to_workflow` | `SendToWorkflow` | — | Send data to a workflow on another BEAM node via RPC |
| `receive_from_workflow` | `ReceiveFromWorkflow` | — | Gate: accepts remote triggers when placed as step 1 |

### Skill API — `AlexClaw.Skills.SkillAPI`

Permission-gated API that all skills (core and dynamic) call for side effects. Core skills have `:all` permissions and pass every check. Dynamic skills declare `permissions/0` and are enforced at runtime.

**Permission categories:**

| Permission | Grants |
|---|---|
| `:llm` | LLM completion and system prompt access |
| `:gateway_send` / `:telegram_send` | Send messages via gateway |
| `:memory_read` / `:memory_write` | Search and store memories |
| `:knowledge_read` / `:knowledge_write` | Search and store knowledge entries |
| `:web_read` | HTTP GET/POST/request |
| `:config_read` | Read config values |
| `:resources_read` | List/get resources |
| `:skill_invoke` | Invoke other skills by name |
| `:skill_write` | Write/read `.ex` files in skills directory |
| `:skill_manage` | Load, unload, reload dynamic skills via SkillRegistry |
| `:workflow_manage` | Create workflows, add steps, run workflows, get results |

The last three permissions enable autonomous agent capabilities — skills can write code, load it, and wire it into workflows programmatically.

### Coder Skill — `AlexClaw.Skills.Coder`

Core skill that autonomously generates dynamic skills from natural language goals using the local LLM (zero cloud API cost). Flow:

1. Extract goal from input
2. Search knowledge base for architecture docs + skill template (RAG context)
3. Build prompt with module name derived from goal
4. Retry loop (configurable, default 3):
   - LLM generates code → extract code block → write to skills dir → load via SkillRegistry
   - On compile/validation error: append error to prompt, retry
5. Optionally create a workflow with the generated skill + telegram_notify step (disabled by default)

Safety: filename validation prevents path traversal, SkillRegistry validates namespace/behaviour/permissions on load, generated workflows are disabled, all code logged for audit.

Shared utilities (`parse_int`, `parse_float`, `sanitize_utf8`, `strip_noise`, `blank?`) live in `AlexClaw.Skills.Helpers`.

---

## Web Automation

Optional browser automation via a Python/Playwright sidecar (`web-automator/`).

- **Record** — start a browser session with noVNC for live interaction, captures user actions as reproducible steps
- **Replay** — headless execution of recorded steps with scraping, screenshots, downloads
- **Resources** — recordings are saved as resources (type: `automation`) with step metadata in JSONB

The sidecar runs as a separate container in docker-compose with Xvfb + noVNC. Enable via `web_automator.enabled` config. Dispatcher commands: `/record`, `/record stop`, `/replay`, `/automate`.

---

## GitHub Security Review

Reviews pull requests and commits for security issues:

- Fetches diff via GitHub API (supports fine-grained tokens per workflow)
- Truncates diff at 24KB for local model compatibility
- LLM produces structured output: RISK LEVEL, FINDINGS, SUMMARY, RECOMMENDATION
- Results stored in Memory (kind: `security_review`)
- Webhook endpoint at `/webhooks/github` with HMAC-SHA256 signature verification via `CachingBodyReader`
- Telegram trigger: `/github pr owner/repo 42` or `/github commit owner/repo <sha>`
- Automatic review on push events to watched branches (configurable)

---

## Database Backups — `AlexClaw.Skills.DbBackup`

Core skill that produces gzip-compressed `pg_dump` backups to a host-mounted directory. Designed to run as a scheduled workflow step.

**How it works:**
1. Verifies `/app/backups` is a real bind mount (not on the container overlay FS) via `/proc/mounts` and device ID comparison
2. Runs `pg_dump` against the production database with `--clean --if-exists`
3. Gzip-compresses the output and writes `alexclaw_backup_YYYYMMDD_HHMMSS.sql.gz`
4. Rotates old backups — keeps the N most recent files (configurable), deletes the rest

**Mount verification strategy:** Docker Desktop (Windows/Mac) routes bind mounts through a Linux VM, so device IDs may match the overlay FS. The skill checks `/proc/mounts` first (which lists bind mounts explicitly on all Docker runtimes), then falls back to device ID comparison. If neither detects a mount, the backup is refused.

**Config keys (Admin UI > Config, category: backup):**
- `backup.enabled` — boolean, must be `true` for the skill to run
- `backup.max_files` — integer, max backup files to keep (default 7)

**Docker setup:** The bind mount is defined in `docker-compose.yml`:
```yaml
volumes:
  - ${BACKUP_DIR:-./backups}:/app/backups
```
Set `BACKUP_DIR` in `.env` to a host path outside the Docker data directory (e.g. `D:/Backups/alexclaw` on Windows, `/mnt/backups/alexclaw` on Linux).

**Typical workflow:** `db_backup` → `telegram_notify` (or `discord_notify`), scheduled daily via cron (e.g. `0 3 * * *`).

---

## Resources — `AlexClaw.Resources`

Shared data objects that workflows can reference. Stored in PostgreSQL.

| Type | Description |
|---|---|
| `rss_feed` | RSS feed URL with name and enabled flag |
| `website` | URL for web browsing/scraping |
| `document` | Inline text content |
| `api` | API endpoint with auth metadata |
| `automation` | Recorded browser automation with step metadata |

Resources can be assigned to workflows. Skills access them via `args[:resources]` in `run/1`. The feeds management page is a convenience wrapper around resources filtered by type `rss_feed`.

---

## MCP Server — `AlexClaw.MCP.Server`

Model Context Protocol server exposing AlexClaw capabilities to external AI clients (Claude Code, Cursor, Claude Desktop). Built on `anubis_mcp` with Streamable HTTP transport.

**Authentication:** Bearer token checked by `AlexClawWeb.Plugs.McpAuth` against `mcp.api_key` in Config. Constant-time comparison via `Plug.Crypto.secure_compare/2`.

**Tools:** All registered skills (core + dynamic) and workflows are exposed as MCP tools. Skills as `skill:<name>`, workflows as `workflow:<name>`. Tool list refreshes dynamically via PubSub when skills are loaded/unloaded.

**Resources:** Six URI templates expose AlexClaw data stores:

| URI Template | Data |
|---|---|
| `alexclaw://resources/{id}` | RSS feeds, websites, documents, APIs |
| `alexclaw://knowledge/{id}` | Knowledge base entries (supports `search:query`) |
| `alexclaw://memory/{id}` | News items, facts, observations (supports `search:query`) |
| `alexclaw://workflows/{id}` | Workflow definitions with steps |
| `alexclaw://runs/{id}` | Workflow execution history |
| `alexclaw://config/{key}` | Settings (sensitive values redacted) |

All templates accept `list` as ID for browsing.

**Policy enforcement:** MCP tool calls go through `PolicyEngine.evaluate/2` with `:mcp` caller type. The `mcp_restriction` policy rule type allows blocking tools by name pattern. Auth flow:

```
Bearer token (transport) → McpAuth plug → PolicyEngine (tool-level) → CapabilityToken (skill-level)
```

**Key modules:**

| Module | Role |
|---|---|
| `AlexClaw.MCP.Server` | Anubis server — init, tool calls, resource reads, PubSub |
| `AlexClaw.MCP.ToolSchema` | Maps skills/workflows to MCP tool definitions (Peri format) |
| `AlexClaw.MCP.ResourceProvider` | Routes resource URIs to context modules |
| `AlexClawWeb.Plugs.McpAuth` | Bearer token validation |
| `AlexClawWeb.Plugs.McpForward` | Runtime forwarder to Anubis StreamableHTTP Plug |

---

## Web Interface

Phoenix LiveView admin UI. Session-based authentication — all routes except `/login` and `/health` require an authenticated session. No JavaScript hooks — fully server-rendered.

| Page | Route | Description |
|---|---|---|
| Dashboard | `/` | System uptime, memory, LLM usage, Google status, recent activity |
| Chat | `/chat` | Interactive conversation with semantic memory search — pick any LLM provider |
| Workflows | `/workflows` | Create/edit/run pipelines, step editor, resource assignment |
| Workflow Runs | `/workflows/:id/runs` | Run history with step-level results and output |
| Skills | `/skills` | Dynamic list from SkillRegistry with descriptions |
| Scheduler | `/scheduler` | Cron jobs, next run times, manual triggers |
| LLM | `/llm` | Provider status, usage counters, custom provider management |
| Resources | `/resources` | Shared resources with type filtering (RSS feeds, websites, APIs, automations) |
| Memory | `/memory` | Browse and search stored knowledge |
| Database | `/database` | Schema browser and backup download |
| Config | `/config` | Runtime configuration editor (collapsible categories) |
| Logs | `/logs` | Real-time log viewer with severity filtering (includes circuit breaker events) |

### API Endpoints

| Endpoint | Auth | Description |
|---|---|---|
| `GET /health` | None | Lightweight liveness check — DB ping, version, status (`ok` / `degraded`). Returns HTTP 503 when DB is unreachable. |
| `GET /metrics` | Session | Rich JSON: system stats, LLM usage, workflow run counts, skill/circuit breaker states, log severity counts, knowledge/memory entry counts |

---

## Project Structure

```
lib/
  alex_claw/
    auth/
      auth_context.ex          # Authorization context struct (caller, type, permission, chain depth)
      policy_engine.ex         # Context-aware policy evaluation (chain depth, tokens, DB rules)
      capability_token.ex      # HMAC-signed Macaroon-style permission tokens
      safe_executor.ex         # Process-isolated execution for dynamic skills
      policy.ex                # Ecto schema for policy rules (rate_limit, time_window, etc.)
      audit_log.ex             # Authorization audit logging (Logger + DB persistence)
      audit_entry.ex           # Ecto schema for auth_audit_log table
      skill_rate_limiter.ex    # Per-skill ETS-based rate limiting GenServer
      totp.ex                  # TOTP 2FA (setup, verify, challenge)
    config/
      crypto.ex                # AES-256-GCM encryption (HKDF key derivation)
      encrypt_existing.ex      # Idempotent plaintext → encrypted migration on boot
      loader.ex                # Seed env → DB, encrypt, load into ETS
      seeder.ex                # Default config definitions (with sensitive flags)
      setting.ex               # Ecto schema for config entries (includes sensitive field)
    google/
      oauth.ex                 # Google OAuth2 flow (state, token exchange)
      token_manager.ex         # Access token cache + auto-refresh GenServer
    knowledge/
      entry.ex                 # Knowledge entry Ecto schema (pgvector)
    llm/
      provider.ex              # Custom provider schema
      usage_entry.ex           # Usage counter Ecto schema
      usage_tracker.ex         # ETS owner + DB persistence GenServer
    memory/
      entry.ex                 # Memory entry Ecto schema (pgvector)
    resources/
      resource.ex              # Resource Ecto schema
      migrator.ex              # Resource migration utilities
    skills/
      circuit_breaker.ex       # Per-skill OTP circuit breaker (GenServer + ETS)
      circuit_breaker_supervisor.ex  # DynamicSupervisor + PubSub lifecycle
      api_request.ex           # HTTP requests with retries
      conversational.ex        # Free-text LLM conversation
      db_backup.ex             # PostgreSQL backup with gzip + rotation to host mount
      discord_notify.ex        # Discord channel delivery (workflow step)
      github_security_review.ex # PR/commit security analysis
      google_calendar.ex       # Google Calendar events
      google_tasks.ex          # Google Tasks list/create
      helpers.ex               # Shared utilities (parse_int, sanitize_utf8, etc.)
      research.ex              # Deep research with memory context
      rss_collector.ex         # RSS fetch, score, notify
      telegram_notify.ex       # Telegram delivery (markdown → HTML)
      web_automation.ex        # Browser recording and replay
      web_browse.ex            # URL fetch and summarize
      coder.ex                 # Autonomous skill generation via local LLM
      shell.ex                 # Whitelisted OS command execution (5-layer security)
      skill_api.ex             # Permission-gated API for all skill side effects
      web_search.ex            # DuckDuckGo search and synthesize
    workflows/
      executor.ex              # Runs workflow steps sequentially
      llm_transform.ex         # Prompt template skill for workflows
      scheduler_sync.ex        # Syncs DB schedules → Quantum jobs
      skill_registry.ex        # Maps skill names → modules (15 skills)
      registry.ex              # Live run tracking (GenServer + ETS)
      workflow.ex              # Workflow Ecto schema
      workflow_resource.ex     # Join schema (workflow ↔ resource)
      workflow_run.ex          # Run history Ecto schema
      workflow_step.ex         # Step Ecto schema (order, config, input_from, routes)
      skill_outcome.ex         # Execution outcome tracking (quality, duration, feedback)
    gateway/
      behaviour.ex             # Gateway behaviour contract
      discord.ex               # Discord bot (Nostrum consumer + REST API)
      router.ex                # Multi-gateway message routing
      telegram.ex              # Telegram bot (long-polling GenServer)
    application.ex             # Supervision tree
    dispatcher.ex              # Command routing (pattern matching, transport-agnostic)
    dispatcher/
      command_parser.ex        # --flag value extraction for --tier and --provider
    gateway.ex                 # Facade — defdelegate to Router
    identity.ex                # Persona / system prompt builder
    knowledge.ex               # Knowledge base store (hybrid search, async embed)
    llm.ex                     # Multi-model LLM router
    log_buffer.ex              # In-memory log ring buffer
    memory.ex                  # Knowledge store API
    message.ex                 # Internal message struct
    rate_limiter.ex            # ETS-based login rate limiting
    rate_limiter/server.ex     # GenServer for ETS ownership + purge
    release.ex                 # Release tasks (migrate, seed)
    repo.ex                    # Ecto repo
    scheduler.ex               # Quantum cron scheduler
    skill.ex                   # Skill behaviour definition
    skill_supervisor.ex        # DynamicSupervisor for skill workers
    mcp/
      server.ex                # MCP server — Anubis callbacks, tool calls, resource reads
      tool_schema.ex           # Maps skills/workflows to MCP tool definitions (Peri format)
      resource_provider.ex     # Routes resource URIs to context modules
  alex_claw_web/
    controllers/
      auth_controller.ex       # Login/logout with rate limiting
      database_controller.ex   # Schema browser, backup download
      github_webhook_controller.ex  # GitHub webhook receiver (HMAC verified)
      health_controller.ex     # GET /health — liveness check (unauthenticated)
      metrics_controller.ex    # GET /metrics — system/LLM/workflow/skill stats (authenticated)
      oauth_callback_controller.ex  # Google OAuth callback handler
    live/admin_live/           # LiveView pages (12 pages, .ex logic + .html.heex templates)
    plugs/
      caching_body_reader.ex   # Caches raw body for webhook HMAC verification
      mcp_auth.ex              # Bearer token auth for /mcp endpoint
      mcp_forward.ex           # Runtime forwarder to Anubis StreamableHTTP Plug
      rate_limit.ex            # Plug for POST /login rate limiting
      require_auth.ex          # Session-based auth guard
    router.ex
web-automator/                 # Python/Playwright browser automation sidecar
  app/
    main.py                    # FastAPI server
    recorder.py                # Browser session recording
    player.py                  # Headless step replay
    browser.py                 # Playwright browser management
    models.py                  # Pydantic models
  Dockerfile
  supervisord.conf             # Xvfb + noVNC + FastAPI
priv/repo/
  migrations/                  # 19 DB migrations
  seeds/                       # Example workflow seeds
config/
  config.exs
  runtime.exs                  # Reads env vars for DB, secret key, Telegram token
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
{:nimble_totp, "~> 1.0"}      # TOTP 2FA
{:eqrcode, "~> 0.2"}          # QR code generation for 2FA setup
{:anubis_mcp, "~> 1.0"}       # MCP server (Streamable HTTP transport)
{:nostrum, "~> 0.10"}          # Discord gateway
{:jason, "~> 1.4"}            # JSON
{:telemetry_metrics, "~> 1.0"}
{:telemetry_poller, "~> 1.0"}
```

---

## Data Flow Examples

### Scheduled Workflow (Morning News Briefing)

```
Quantum fires cron job (0 7 * * *)
  → SchedulerSync dispatches → TaskSupervisor.start_child
    → Workflows.Executor.run(workflow_id)
      → Step 1: rss_collector skill
        ├── Fetch feeds concurrently (Req + SweetXml)
        ├── Deduplicate via Memory.exists?
        ├── Batch-score relevance via single LLM call (tier: light)
        ├── Filter by score threshold, keep top N
        ├── Store in Memory, notify per item
        └── Return collected items as output
      → Step 2: llm_transform skill
        ├── Interpolate items into prompt template
        ├── LLM.complete(prompt, tier: step.llm_tier)
        └── Return summary as output
      → Step 3: telegram_notify skill
        ├── Convert markdown → Telegram HTML
        └── Send to configured chat_id
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
  → CachingBodyReader caches raw body
    → Plug.Parsers decodes JSON
      → WebhookController verifies HMAC-SHA256 (raw body vs signature)
        → TaskSupervisor.start_child
          → GitHubSecurityReview.review_commit(repo, sha)
            ├── Fetch diff via GitHub API
            ├── Truncate to 24KB
            ├── LLM.complete(analysis_prompt, tier: :medium)
            ├── Memory.store(:security_review, report)
            └── Gateway.send_message(report)
```

### Google OAuth Connection

```
User sends "/connect google" via Telegram
  → Dispatcher → OAuth.authorize_url(chat_id)
    ├── Generate random state token
    ├── Store {state → chat_id} in ETS (10 min TTL)
    └── Gateway.send_message(auth_url)
  → User clicks link, authorizes in Google
  → Google redirects to /auth/google/callback?code=...&state=...
    → OAuthCallbackController.google(conn, params)
      ├── OAuth.handle_callback(code, state)
      ├── Exchange code for tokens
      ├── Store refresh_token in Config
      ├── TokenManager caches access_token in ETS
      └── Gateway.send_message("Connected!")
```

---

## Security

- Session-based authentication on all admin routes
- ETS-based login rate limiting (configurable attempts and block duration)
- Optional TOTP 2FA for sensitive workflow execution
- HMAC-SHA256 webhook signature verification with timing-safe comparison
- CachingBodyReader ensures HMAC is verified against original payload
- Telegram chat_id filtering (rejects messages from unauthorized users)
- Sensitive config values (API keys, tokens) encrypted at rest with AES-256-GCM
- Encryption key derived from `SECRET_KEY_BASE` via HKDF — changing the secret invalidates encrypted values
- Sensitive values masked in admin UI
- External skill tagging (`external/0`) with AST-based detection for dynamic skills — undeclared HTTP/socket calls rejected at load time
- 7-layer content sanitizer (`AlexClaw.ContentSanitizer`) — hidden HTML/CSS detection, zero-width unicode stripping, 101 known injection patterns from runtime JSON, imperative tone heuristic for novel payloads
- Pre-LLM sanitization in external skills, post-LLM auto-sanitization in the workflow executor
- See [SECURITY.md](SECURITY.md) for full policy and deployment hardening
