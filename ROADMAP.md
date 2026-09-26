# Roadmap

Planned features and improvements, roughly ordered by priority.

---

## Next Up

### Google Calendar Event Creation

Calendar is currently read-only (`fetch_events`). Adding event creation would complete the integration:

- `/event add <title> <date> <time>` Telegram command
- `google_calendar` skill with `"action": "create"` config
- Requires upgrading OAuth scope to `calendar.events`

---

## Planned

### External Event Triggers

Workflows run on a cron schedule, on demand, from MCP, from another node, or from a GitHub webhook (pull requests and pushes, one configured workflow). Planned event sources:

- RSS item with relevance score above threshold
- More GitHub events (new issue, review requested)
- API polling with change detection

### Workflow Templates

- Pre-built workflow templates for common patterns (daily briefing, PR review, content monitoring)

### Analytics Dashboard

The current dashboard shows basic stats. Planned additions:

- Workflow success/failure rates over time
- LLM cost tracking per provider and per workflow
- Execution time trends

### Email Integration

SMTP skill for sending email notifications as a workflow step. IMAP polling as a workflow trigger source.

### ~~Multi-Gateway Support~~ ✅ Discord (v0.3.9)

Gateway behaviour abstraction with multi-transport Router. Telegram and Discord run simultaneously. Discord uses Nostrum (WebSocket + REST API). Responses route back to the originating transport via explicit `gateway: msg.gateway` threading. Since 0.4.0 each gateway answers only its owner — a user id in a chat or channel, set in the admin UI. Slack planned as a future addition.

### Slack Gateway

Slack bot + incoming webhooks. Same Gateway behaviour pattern as Telegram and Discord.

### ~~Shell Skill (Container Introspection)~~ ✅ Completed (v0.3.4)

Execute OS commands inside the AlexClaw container via Telegram/Discord. 5-layer defense-in-depth: disabled by default, 2FA gate, command whitelist with word-boundary check, metacharacter blocklist, no shell interpretation. Configurable timeout and output truncation. Since 0.4.0 it is a privileged workflow step only — scheduled runs, or admin-UI runs with a 2FA code; the `/shell` chat command no longer runs anything.

### ~~Autonomous Skill Generation (Coder)~~ ✅ Completed (v0.3.5)

An LLM generates dynamic skills from natural language goals. Retry loop with error feedback, knowledge base RAG context. Generated code passes the full validation pipeline (namespace, behaviour, permissions). Since 0.4.0 generation is the admin UI's Forge page only, with a provider selector (local by default); contained code within the unattended permissions loads at once, more permissions need a 2FA code, and code calling outside the containment allowlist never loads. The `/coder` chat command and workflow creation by a skill were removed. See [SELF_AWARENESS.md](SELF_AWARENESS.md).

### ~~Composable Skill Decomposition~~ ✅ Completed (v0.3.15)

Separated fetch from LLM processing. New pure-fetch skills (`web_fetch`, `web_search_fetch`, `rss_fetch`) do one thing — fetch data, return it. New `llm_score` skill handles batch item scoring. Workflows compose these primitives: `rss_fetch → llm_score → llm_transform → telegram_notify`. Monolithic skills (`web_browse`, `web_search`, `rss_collector`) deprecated, removal in a later release.

### ~~Content Sanitization & Prompt Injection Defense~~ ✅ Completed (v0.3.14)

7-layer heuristic sanitizer protects external-facing skills from prompt injection attacks. Hidden HTML/CSS detection, zero-width unicode stripping, 101 known injection patterns (sourced from NVIDIA Garak probe library) loaded from runtime JSON, imperative tone heuristic for novel payloads. Core skills tagged with `external/0` callback; dynamic skills AST-scanned at load time — undeclared HTTP/socket calls rejected (fail-closed). Pre-LLM sanitization in `web_browse` and `web_search`, post-LLM auto-sanitization in the workflow executor for all external skills.

### Embedded Injection Classifier (Planned)

Embed a tiny LLM (Qwen2.5-0.5B or SmolLM2-360M) inside the container for binary injection classification. Two-pass architecture: regex heuristics catch the obvious 80%, model classifies ambiguous sentences. CPU-only, sub-100ms, zero API cost. Ship zero-shot first, measure, then decide on fine-tuning.

### ~~Reasoning Loop Engine~~ ✅ Completed (v0.3.21)

Autonomous plan-execute-evaluate cycle. The LLM decomposes a goal into a multi-step plan, invokes whitelisted skills, evaluates results on a 1-5 rubric, and decides whether to continue, adjust, ask the user, or declare done. Default tier `local` (configurable). Deterministic pre-filter handles obvious decisions without an LLM call. Plan validation rejects malformed steps before execution. Working memory compression every 3 iterations. Proportional time budget. Real-time intervention: pause, resume, steer, abort, step override. Orphaned session cleanup (terminate callback, boot sweep, mount check). Full audit trail with skill outputs embedded to pgvector for future session context. Available from the chat page in Reasoning mode. See [docs/architecture/reasoning-loop.md](docs/architecture/reasoning-loop.md).

### ~~Multi-Node BEAM Clustering~~ ✅ Completed (v0.3.8)

Multiple AlexClaw instances connected via Erlang distribution exchange workflow outputs over BEAM. Each node runs its own sequential executor — no parallel step changes. ClusterManager GenServer handles auto-registration on connect, node monitoring (`:nodeup`/`:nodedown`), and remote workflow triggers via `:rpc.call`. Two new core skills: `send_to_workflow` (sends data to a workflow on another node, 5s default timeout) and `receive_from_workflow` (gate skill — must be step 1 to accept remote triggers, optional `allowed_nodes` ACL). Cluster admin UI page with node status and ping. Workflow "Run on" dropdown for node assignment (cluster-wide or pinned). `docker-compose_swarm.yml` for multi-node testing with long-name distribution (`alexclaw@nodeN.local`). EPMD bundled in runtime image. Since 0.4.0 another node is registered in the admin UI only (connecting registers nothing), a remote trigger is a `GenServer.call` performed through the control plane and audited, and `allowed_nodes` must name the sender (an empty list allows no one).

---

## Someday

### ~~Knowledge Base RAG~~ ✅ Completed (v0.3.3)

Separate `knowledge_entries` table with pgvector HNSW index for documentation and reference material. HexDocs scraper skill discovers modules via sidebar JSON, chunks by section/function, and embeds via local nomic-embed-text or Gemini. Chat RAG integration with context source selector (Docs/Memory/Both/None). Keyword-first hybrid search for precise documentation retrieval. LLM API key resolution falls back from provider record to config settings. Currently 22 packages scraped (4200+ chunks), including full Elixir stdlib and 53 official guides.

### ~~Semantic Search (Memory)~~ ✅ Completed (v0.2.1)

Hybrid search combining pgvector cosine similarity and keyword matching. Embeddings generated asynchronously via Gemini `text-embedding-004`, Ollama `nomic-embed-text`, or any OpenAI-compatible endpoint. 768-dimension vectors with HNSW index. All skills auto-embed stored knowledge in the background. Batch re-embed support for model switching.

### ~~Dynamic Skill Hot-Loading~~ ✅ Completed (v0.2.0)

Runtime skill loading. Permissions checked by `SkillAPI`, SHA256 integrity checks, persistence across restarts. Core skills unaffected. Since 0.4.0 a skill is uploaded on the admin UI's Skills page only, loaded with a 2FA code for that load, and every dynamic skill is contained to an allowlist of calls, checked on its syntax tree at every load and every boot. **Still under heavy development — API may change.**

### ~~Security redesign around OpenBao~~ ✅ Completed (v0.4.0)

Every credential in a bundled OpenBao, bound to its destination; the database holds references, and nothing is encrypted with `SECRET_KEY_BASE`. One control plane for every privileged action from every entry point, audited. Chat and MCP operate AlexClaw but never change it. Privileged steps run only in scheduled or 2FA-approved admin runs. Containment for every dynamic skill. The admin password is stored as a hash; the TOTP key lives in OpenBao's TOTP engine. See [SECURITY.md](SECURITY.md).

### Visual Automation Editor

Replace raw JSON editing for web automation recipes with a visual step editor in the admin UI. Drag-and-drop step ordering, selector picker, live preview.

### Workflow Step Dependencies

Allow workflows to depend on other workflows — "run B only after A completes successfully." Enables complex multi-workflow pipelines.

### Per-Skill Rate Limiting

Global LLM rate limits exist but there's no per-skill throttling. Would prevent a single noisy workflow from exhausting daily quotas.

### Pre-built Docker Images

Currently built from source on every `docker compose up`. Publishing multi-arch images to GitHub Container Registry would cut setup time significantly.

---

## Not Planned

These are explicitly out of scope for the foreseeable future:

- **Multi-user access control** — AlexClaw is a single-user personal agent by design
- **Local file system access** — security risk; use API Request skill to interact with file-serving APIs instead
- **Mobile app** — Telegram serves as the mobile interface
