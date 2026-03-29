# Changelog

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
