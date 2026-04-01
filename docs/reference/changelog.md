# Changelog

## v0.3.21 — RAG Pipeline (2026-04-01)

- **RAG pipeline overhaul** — 5-phase improvement to retrieval-augmented generation
  - **Embedding metadata** — tracks `embedding_model`, `embedding_dim`, `embedded_at` per entry; `stale_embedding_count/1` detects model mismatches; Embeddings panel on Services page
  - **Relevance grading** — `min_score` opt filters vector results via SQL cosine similarity threshold
  - **Query rewriting** — `RAG.QueryRewriter` generates 2-3 semantic variants via light-tier LLM with ETS cache (5min TTL); opt-in via `rewrite: true`
  - **Semantic chunking** — `RAG.Chunker` splits on markdown headers, function defs, paragraphs (not sliding window); long content auto-chunks into parent + children with `parent_id`/`chunk_index`; search deduplicates chunks from same parent
  - **Fallback routing** — `RAG.Fallback` searches both Memory + Knowledge with rewriting + grading; Research skill now cross-store; context section omitted when nothing found
- **Research skill** — now uses `search_with_fallback/2` for cross-store RAG with rewriting and relevance grading
- **CodeGenerator** — knowledge searches now use query rewriting for broader retrieval
- **GitHub Security Review** — refactored as pure diff fetcher (no embedded LLM); 5 modes (latest_pr, all_prs, latest_push, specific_pr, specific_commit); config presets in step editor
- **Workflow step editor fixes** — save no longer closes the editor; scaffold values now persist correctly; nil llm_tier no longer blocks saves
- **LLM Transform** — removed config field, added 10 prompt presets (Security Review, Code Review, Changelog, etc.)

## v0.3.20 — Services Page (2026-03-31)

- **Services page** — new `/services` admin page showing external service status with real connectivity checks
  - **Database** — verifies PostgreSQL connectivity via `SELECT 1`
  - **Google API** — checks OAuth2 token status (connected/expired/not configured)
  - **Telegram Bot** — sends a real test message to the configured chat
  - **Discord Bot** — sends a real test message to the configured channel
  - **2FA (TOTP)** — triggers a challenge via Telegram, auto-updates via PubSub on code verification
  - **Ollama** — queries `/api/tags`, reports loaded models
  - **LM Studio** — queries `/v1/models`, reports loaded models
  - **GitHub API** — authenticates with stored PAT, reports username
  - **Web Automator** — checks `/status` on the browser sidecar
- **Config seeder fix** — env-backed settings no longer overwrite DB values on boot; Config page is now the sole source of truth after first seed
- **Dashboard cleanup** — removed Google status card from dashboard (moved to Services), node name moved to dashboard header next to version
- **Nav bar** — added Services menu item, reduced spacing between AlexClaw title and menu links

## v0.3.18 — Forge & Knowledge Pipeline (2026-03-29)

- **Forge page** (pre-alpha) — interactive skill generation with two-column UI (chat + code output), auto-iterate with configurable retries, real-time status, structural validation for external skills
- **Chat simplified** — stripped RAG/knowledge search, now a clean conversational chat with model selection
- **CodeGenerator** — shared skill generation module extracted from Coder skill, reusable by both Forge UI and Coder workflow skill
- **Executor timeout from config** — `timeout_ms` in step config JSON overrides the 30s default SafeExecutor timeout
- **Scraper improvements** — all 5 knowledge scrapers now support `timeout_ms`, delay between items, deadline-based execution, and detailed reporting (stored/skipped/failed/timeout per item)
- **HexDocs guides scraper** — new skill scraping guide/extra pages (README, getting started, deployment docs) — 649 guide chunks indexed
- **Skill UI feedback** — Reload/Unload/Upload buttons show "Waiting 2FA..." with pulse animation during 2FA challenge
- **Workflow runs counter** — now refreshes automatically when a run completes
- **Browser User-Agent** — all SkillAPI HTTP calls now include a default browser User-Agent header to prevent site blocking
- **Convention fixes** — 164 violations reduced to 19 (all intentional process_dictionary usage)
- **Skill template** — updated with `external/0`, `step_fields/0`, `config_hint/0`, `config_scaffold/0` documentation

## v0.3.16 — Workflow Export/Import (2026-03-29)

- **Workflow export** — self-contained JSON files with definition, steps, and full resource data
- **Workflow import** — file upload in Admin UI, resources matched by name+URL or created automatically, disabled by default with `(imported N)` suffix
- **Workflow name filter** — search/filter the workflow list by name
- **Action buttons** — workflow row actions restyled as colored pill buttons
- **Bug fix** — `duplicate_workflow` now copies `input_from` and `routes` fields
- **Docker naming** — services renamed to `alexclaw-prod`, `db-prod`, `db-test` for clarity
- **Makefile** — quiet test builds, auto-teardown after tests, `test-down` target
- **Dynamic skill metadata** — skills declare their own UI fields via 7 new optional callbacks (`step_fields`, `config_hint`, `config_scaffold`, `config_presets`, `prompt_presets`, `config_help`, `prompt_help`). Step editor renders dynamically — zero hardcoded skill knowledge in the LiveView
- **Docs** — README, INSTALLATION, architecture, writing-skills, and readthedocs pages updated

## v0.3.13 — MCP Server (2026-03-27)

**New: Model Context Protocol integration**

- MCP server exposing all skills and workflows as tools via Streamable HTTP transport
- 6 resource URI templates for browsing knowledge, memory, workflows, runs, config, and resources
- Bearer token authentication with constant-time comparison
- `mcp_restriction` policy rule type for fine-grained tool blocking
- PolicyEngine extended with `:mcp` caller type
- AuthContext extended with `tool_name` field and `build_mcp/2`
- `/health` and `/metrics` endpoints report MCP status
- Architecture, security, and README documentation updated
- Full test coverage for MCP modules (855 tests, 0 failures)

## v0.3.12 — Execution Outcome Annotation

- `skill_outcomes` table for tracking execution quality
- `/rate` gateway command for thumbs up/down rating
- SkillAPI integration for episodic memory queries
- Per-step outcome recording with timing and output snapshots

## v0.3.11 — Workflow Registry & Live Run Control

- Real-time workflow tracking via GenServer + ETS
- Cancel running workflows from Admin UI or gateway commands
- PubSub events for step-by-step progress in the UI
- Automatic crash cleanup for orphaned runs

## v0.3.10 — Coding Conventions Enforcement

- Giulia analysis report integration
- 195 convention violations fixed
- `enforce_keys` on all structs

## v0.3.9 — Discord Gateway

- Full bidirectional Discord support via Nostrum
- Gateway behaviour pattern for multi-transport messaging
- Simultaneous Telegram + Discord operation
- Per-step `channel_id` for Discord notifications

## Earlier Versions

See [git history](https://github.com/thatsme/AlexClaw/commits/main) for the complete changelog.
