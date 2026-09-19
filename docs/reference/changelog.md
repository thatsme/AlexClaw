# Changelog

## v0.3.22 — Security Hardening (2026-09-19)

Security release. Several of these change existing behaviour — read the
breaking-changes note before upgrading.

- **Shell skill — callers cannot redefine their own limits** — the allowlist, blocklist and exact-command list are read from Config or the compiled defaults only. A workflow step previously supplied its own `whitelist`, letting any step run any command
  - Default allowlist narrowed to `df free uptime uname whoami hostname date ls`
  - Removed: `cat /proc` (matched `/proc/self/environ`, leaking the environment), `bin/alex_claw` (arbitrary code execution via `eval`), `curl`, `git`, `ping`, `nslookup`
  - `ps` is now exact-match `ps aux`; `ps e` and `ps eww` print other processes' environments
  - New `shell.exact_commands`, compared byte-for-byte (default `cat /proc/meminfo`, `cat /proc/loadavg`, `ps aux`)
  - A step may narrow `timeout_seconds` and `max_output_chars` but never widen them
- **Dynamic skills — vetted as a syntax tree before compiling** — `Code.compile_file/1` defined every module in a file and ran each module body before any check. A skill could ship a second module replacing `AlexClaw.Auth.PolicyEngine`, or act at compile time
  - The file must be exactly one `defmodule` in `AlexClaw.Skills.Dynamic.*`, and nothing else at the top level
  - Module body limited to `def`, `defp`, `@`, `alias`, `require`, `import`; attributes must be literals or `~w`/`~s`/`~r` sigils
  - `use`, `@on_load`, `@after_compile`, `@before_compile`, `@on_definition`, `@compile` and `unquote` rejected
  - `import`/`require` restricted to `Logger`, `AlexClaw.Skills.Helpers`, `SweetXml` anywhere in the file
  - A reload that fails validation no longer unloads the working skill
- **Skill uploads staged** — uploads land in `<skills_dir>/pending/` and move into place only after the 2FA code is verified, so an upload can no longer overwrite a running skill's file beforehand. Stale pending files are swept after an hour
- **MCP — dangerous tools denied by default** — `skill:shell`, `skill:coder`, `skill:db_backup` and `skill:web_automation` are seeded as `mcp_restriction` denies. `mcp_restriction` was also missing from `Policy`'s valid rule types, so the admin UI could never have created one. Adds an optional `match` mode (`exact` or `contains`)
- **2FA cannot be turned off without a code** — `/disable 2fa` now requires `/disable 2fa <code>` and verifies it
- **Workflows marked `requires_2fa` are gated in the admin UI** — the Run button called the executor directly, bypassing the check the gateway applied. Extracted as `AlexClaw.Auth.Gate`
- **Knowledge deletes go through SkillAPI** — `Knowledge.delete_by_source_prefix/2` requires a kind and a non-empty prefix and escapes LIKE metacharacters; `SkillAPI.knowledge_delete/2` gates it behind `:knowledge_write`. A skill was calling `Repo.delete_all/1` directly
- **Reasoning loop — task and timer lifecycle** — aborting a session left the LLM task running; the time budget kept counting while paused or waiting on the user; `override_step` orphaned an in-flight task; `count_recent_adjusts` counted the whole session instead of a recent window
- **Boot-time skill load failures are broadcast** — a skill refused by the stricter gate after upgrade is reported, not just logged
- **Tests** — live-network tests tagged `:external` and excluded by default (`mix test --include external` to run them); added `lazy_html` for LiveView click testing

### Breaking changes

- **2FA now fails closed.** `/shell`, workflows marked `requires_2fa`, and `/skill load|unload|reload` are **refused** when TOTP is not configured, where they previously ran unprotected. Set up 2FA with `/setup 2fa` before upgrading if you rely on these.
- **Dynamic skills using `use`, computed module attributes, or `import`/`require` outside `[Logger, AlexClaw.Skills.Helpers, SweetXml]` no longer load.** Check your skills volume before upgrading — a rejected skill is reported over the gateway on boot and stays inactive until fixed.
- **Shell commands relying on `cat /proc/*`, `curl`, `git`, `ping`, `nslookup`, `bin/alex_claw` or bare `ps` will be rejected.** Add what you need to `shell.whitelist` or `shell.exact_commands` deliberately.
- **MCP calls to `skill:shell`, `skill:coder`, `skill:db_backup` and `skill:web_automation` are denied.** Disable or delete the seeded policy in Admin > Policies to re-enable one.

## Unreleased

- **Reasoning loop — `:waiting_user` exit transitions** — both unblock paths now resume the loop instead of dead-ending
  - `resume` after `add_context` (the chat answer path) transitions to `:planning`
  - `steer` from `:waiting_user` records the guidance, then transitions to `:planning`
  - Both replan from scratch rather than continuing — user input can invalidate the existing plan
- **Reasoning loop — terminal status preserved** — `Loop.terminate/2` no longer overwrites a session's final status
- **Chat page** — `AdminLive.Chat` routed through the `Reasoning` context instead of calling the loop directly
- **LLM test seam** — `LLM.Behaviour` + `LLM.Real` split allows mock substitution under Mox
- **Test coverage** — integration tests for `Reasoning.Loop` over the Mox seam; `SkillRateLimiter` sliding-window behaviour
- **Dependencies** — added `timex`, `csv`, `yaml_elixir`; expanded the hexdocs scraper fixture
- **Documentation** — reasoning loop documented in the readthedocs architecture section, README, and roadmap

## v0.3.21 — Reasoning Loop (2026-04-06)

- **[Reasoning loop engine](../architecture/reasoning-loop.md)** — autonomous plan-execute-evaluate cycle
  - LLM decomposes goals into multi-step plans, executes whitelisted skills, evaluates results, and iterates
  - Configurable LLM tier (default: local) — route to stronger models via `reasoning.llm_tier`
  - Deterministic decision pre-filter skips LLM for obvious cases (0ms decisions)
  - Deterministic plan validation rejects malformed steps before execution
  - Working memory compression every 3 iterations
  - Evaluation score trend (improving/stable/degrading) in decision prompt
  - Proportional time budget (~300s per step, scales with plan size)
  - User intervention: pause, resume, steer, abort, step override (real-time via PubSub)
  - Skill outputs embedded to pgvector for future session context
  - Orphaned session cleanup on process death, app restart, and page load
  - Full audit trail: every prompt, response, skill call, rubric score, and working memory snapshot persisted
- **Chat page** — dual-mode interface (Chat / Reasoning toggle) with plan view, step timeline, and intervention controls
- **Skill descriptions** — clarified web_search (snippets only), web_fetch (full page content), web_search_fetch (search + full content)

## v0.3.20 — Services Page, RAG Pipeline (2026-04-01)

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
- **RAG pipeline overhaul** — embedding metadata, relevance grading, query rewriting, semantic chunking, fallback routing
- **Research skill** — cross-store RAG with rewriting and relevance grading
- **GitHub Security Review** — refactored as pure diff fetcher; 5 modes
- **Workflow step editor fixes** — save no longer closes editor; nil llm_tier fix
- **LLM Transform** — 10 prompt presets (Security Review, Code Review, Changelog, etc.)

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
