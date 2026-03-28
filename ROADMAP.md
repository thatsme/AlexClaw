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

Workflows can only run on a cron schedule or manual trigger. Planned event sources:

- RSS item with relevance score above threshold
- GitHub webhook events (new issue, review requested)
- API polling with change detection

### Workflow Templates & Export

- Pre-built workflow templates for common patterns (daily briefing, PR review, content monitoring)
- Export/import workflows as JSON for sharing between instances

### Analytics Dashboard

The current dashboard shows basic stats. Planned additions:

- Workflow success/failure rates over time
- LLM cost tracking per provider and per workflow
- Execution time trends

### Email Integration

SMTP skill for sending email notifications as a workflow step. IMAP polling as a workflow trigger source.

### ~~Multi-Gateway Support~~ ✅ Discord (v0.4.0)

Gateway behaviour abstraction with multi-transport Router. Telegram and Discord run simultaneously. Discord uses Nostrum (WebSocket + REST API). Responses route back to the originating transport via explicit `gateway: msg.gateway` threading. Both gateways auto-detect channel/chat ID on first message. Slack planned as a future addition.

### Slack Gateway

Slack bot + incoming webhooks. Same Gateway behaviour pattern as Telegram and Discord.

### ~~Shell Skill (Container Introspection)~~ ✅ Completed (v0.3.4)

Execute OS commands inside the AlexClaw container via Telegram/Discord. 5-layer defense-in-depth: disabled by default, 2FA gate, command whitelist with word-boundary check, metacharacter blocklist, no shell interpretation. Configurable timeout and output truncation. Available as both `/shell <command>` and a workflow step.

### ~~Autonomous Skill Generation (Coder)~~ ✅ Completed (v0.3.5)

Local LLM generates dynamic skills from natural language goals via `/coder <goal>`. SkillAPI extended with `:skill_write`, `:skill_manage`, `:workflow_manage` permissions. Retry loop with error feedback, knowledge base RAG context, optional workflow creation. Zero cloud API cost (always uses `tier: :local`). Generated code passes full validation pipeline (namespace, behaviour, permissions). See [SELF_AWARENESS.md](docs/SELF_AWARENESS.md).

### ~~Composable Skill Decomposition~~ ✅ Completed (v0.3.15)

Separated fetch from LLM processing. New pure-fetch skills (`web_fetch`, `web_search_fetch`, `rss_fetch`) do one thing — fetch data, return it. New `llm_score` skill handles batch item scoring. Workflows compose these primitives: `rss_fetch → llm_score → llm_transform → telegram_notify`. Monolithic skills (`web_browse`, `web_search`, `rss_collector`) deprecated, removal in v0.4.0.

### ~~Content Sanitization & Prompt Injection Defense~~ ✅ Completed (v0.3.14)

7-layer heuristic sanitizer protects external-facing skills from prompt injection attacks. Hidden HTML/CSS detection, zero-width unicode stripping, 101 known injection patterns (sourced from NVIDIA Garak probe library) loaded from runtime JSON, imperative tone heuristic for novel payloads. Core skills tagged with `external/0` callback; dynamic skills AST-scanned at load time — undeclared HTTP/socket calls rejected (fail-closed). Pre-LLM sanitization in `web_browse` and `web_search`, post-LLM auto-sanitization in the workflow executor for all external skills.

### Embedded Injection Classifier (Planned)

Embed a tiny LLM (Qwen2.5-0.5B or SmolLM2-360M) inside the container for binary injection classification. Two-pass architecture: regex heuristics catch the obvious 80%, model classifies ambiguous sentences. CPU-only, sub-100ms, zero API cost. Ship zero-shot first, measure, then decide on fine-tuning.

### ~~Multi-Node BEAM Clustering~~ ✅ Completed (v0.3.8)

Multiple AlexClaw instances connected via Erlang distribution exchange workflow outputs over BEAM. Each node runs its own sequential executor — no parallel step changes. ClusterManager GenServer handles auto-registration on connect, node monitoring (`:nodeup`/`:nodedown`), and remote workflow triggers via `:rpc.call`. Two new core skills: `send_to_workflow` (sends data to a workflow on another node, 5s default timeout) and `receive_from_workflow` (gate skill — must be step 1 to accept remote triggers, optional `allowed_nodes` ACL). Cluster admin UI page with node status and ping. Workflow "Run on" dropdown for node assignment (cluster-wide or pinned). `docker-compose_swarm.yml` for multi-node testing with long-name distribution (`alexclaw@nodeN.local`). EPMD bundled in runtime image.

---

## Someday

### ~~Knowledge Base RAG~~ ✅ Completed (v0.3.3)

Separate `knowledge_entries` table with pgvector HNSW index for documentation and reference material. HexDocs scraper skill discovers modules via sidebar JSON, chunks by section/function, and embeds via local nomic-embed-text or Gemini. Chat RAG integration with context source selector (Docs/Memory/Both/None). Keyword-first hybrid search for precise documentation retrieval. LLM API key resolution falls back from provider record to config settings. Currently 22 packages scraped (4200+ chunks), including full Elixir stdlib and 53 official guides.

### ~~Semantic Search (Memory)~~ ✅ Completed (v0.2.1)

Hybrid search combining pgvector cosine similarity and keyword matching. Embeddings generated asynchronously via Gemini `text-embedding-004`, Ollama `nomic-embed-text`, or any OpenAI-compatible endpoint. 768-dimension vectors with HNSW index. All skills auto-embed stored knowledge in the background. Batch re-embed support for model switching.

### ~~Dynamic Skill Hot-Loading~~ ✅ Completed (v0.2.0)

Runtime skill loading via `Code.compile_file`. Upload `.ex` files through the admin UI or Telegram commands. Permission sandbox via `SkillAPI`, SHA256 integrity checks, persistence across restarts. Core skills unaffected. **Still under heavy development — API may change.**

### ~~Secrets Encryption at Rest~~ ✅ Completed (v0.1.1)

Sensitive config values (API keys, tokens) are now encrypted at rest using AES-256-GCM, derived from `SECRET_KEY_BASE`. Existing plaintext values are automatically encrypted on startup.

### SECRET_KEY_BASE Rotation Tool

Changing `SECRET_KEY_BASE` renders all AES-256-GCM encrypted settings unreadable. A CLI migration tool is needed:

- Accept old and new key as arguments
- Decrypt all sensitive settings with old key, re-encrypt with new key
- Validate round-trip before committing changes
- Support dry-run mode to preview affected rows

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
