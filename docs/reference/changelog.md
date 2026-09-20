# Changelog

## v0.3.27 — Control-Plane Elevation (2026-09-20)

**BEHAVIOUR CHANGE — without 2FA configured, the admin control plane is
read-only.** Configuration, authorization policies, LLM providers, API
resources, cluster membership, workflow edits and database restores are all
refused until a second factor exists. Configure a gateway with
`TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` or `DISCORD_BOT_TOKEN` /
`DISCORD_CHANNEL_ID`, run `/setup 2fa` there, and the control plane opens to
elevation. An upgrade on an instance without 2FA will find its admin pages
read-only until that is done.

The admin password authenticated a session and authorised everything that
session could reach. `config.ex` and `policies.ex` called no gate at all, so a
password-only session could edit `shell.whitelist`, the `mcp.*` and `auth.*`
settings, and delete authorization policies — which is to say it could undo the
shell narrowing, the MCP denials and the 2FA settings shipped in 0.3.22 through
0.3.26 from an ungated page.

- **Control-plane changes need an elevation** — one TOTP code, verified once,
  granting fifteen minutes of write authority to one session. Configuration,
  authorization policies, LLM providers, API resources, cluster membership, and
  workflows and their steps are all gated
  - The window is fixed rather than sliding: fifteen minutes after the code was
    accepted the session is read-only again, busy or idle
  - Elevation is keyed by a random session identifier minted at login and
    revoked at logout. Only a fingerprint of it reaches the audit log or a
    PubSub topic
  - Checks run in the event handler, not in the template. A refused event leaves
    the database untouched, and both writes and refusals are audited with the
    key or record touched and its old and new values, secrets masked
  - `AlexClaw.Auth.Elevation` owns a `:protected` ETS table: a process that
    could insert a row could elevate itself, so writes happen in the owner
  - Granting reuses the existing gate, so the attempt limit and replay guard
    from 0.3.26 apply to elevation without being reimplemented
- **`auth.totp.*` is no longer editable from the Config page**, at any
  elevation, and deleting those keys is refused for the same reason. They are
  written by `/setup 2fa` and `/disable 2fa` on a gateway. Whether elevation is
  enforced is decided by `auth.totp.enabled`; editable from behind the gate it
  protects, it would be the way to switch that gate off
- **A database restore is challenged every time** and is never covered by an
  elevation. It runs arbitrary SQL against the live database as the
  application's own user, reaching the settings and policy tables without
  passing through either. The upload is staged while the code is outstanding and
  discarded whether the restore runs or not
- **Running a workflow follows one rule from both pages** — the `requires_2fa`
  check moved into `AlexClaw.Workflows.Launch`, which the Workflows and
  Scheduler pages both call. The Scheduler page previously called
  `Executor.run/1` directly, so a workflow challenged on one page ran unchallenged
  from the other
- **Instances without a second factor are read-only** — every control-plane
  event is refused and audited as `no_second_factor`, and every gated page says
  so and says how to fix it. There is no password-only path, and no variable
  that disables the gate
  - `DISCORD_BOT_TOKEN` and `DISCORD_CHANNEL_ID` join `TELEGRAM_BOT_TOKEN` and
    `TELEGRAM_CHAT_ID` as bootstrap variables, read whenever the matching
    setting is empty so a fresh instance can be asked for a code. A setting wins
    once it holds a value
  - Boot logs a warning, and sends one gateway message where a gateway is
    reachable: "Admin config is read-only until 2FA is configured: /setup 2fa"
- **The app gets 30 seconds to shut down** (`stop_grace_period`) — Docker's
  default 10 seconds was shorter than the supervision tree takes to unwind, so
  every stop ended in SIGKILL and in-flight workflow runs stayed recorded as
  executing. This is the whole of the exit-137 question; there was no memory
  problem
- **New invariant** — a test reads each gated LiveView's source and follows
  every `handle_event` clause through the functions it calls, failing the build
  when a clause can reach a write without reaching a gate. A new write event has
  to be gated or allow-listed with a reason
- **CI runs Credo** against the merge base, so issues a branch introduces fail
  the build while the 26 that predate the gate do not. The strict configuration
  is now tracked rather than gitignored, which is what the diff baseline reads

## v0.3.26 — Secrets, Privileged Invocation, and Settings That Lie (2026-09-20)

Closes two routes a skill could take to something it was never granted, and
removes eleven settings that promised an effect the code never had.

**Requires PostgreSQL 16 or later.** The `shell.whitelist` migration uses the
`IS JSON ARRAY` predicate to compare stored entries as a set. All shipped
compose files pin `pgvector/pgvector:pg17`; an install on an older server would
fail at migrate with a syntax error.

- **Secrets do not reach skills** — `SkillAPI.config_get/3` returned whatever the config cache held, and the cache holds decrypted plaintext. It now returns `{:error, :sensitive}` for any setting marked sensitive, and for any key the cache does not know
  - The ETS cache carries each row's `sensitive` flag beside its value, so the check needs no database round-trip
  - `auth.totp.secret` is out of the cache entirely: `AlexClaw.Auth.TOTP.secret/0` reads the row and decrypts per verification, so `Config.get/2` cannot serve it at all
  - `SkillAPI.list_resources/2` and `get_resource/2` drop `metadata["auth"]` and strip userinfo from the resource URL. `:resources_read` is inside the auto-load ceiling and a resource row carries the credential `api_request` authenticates with
- **The 0.3.22 shell narrowing applied only to installs without a seeded `shell.whitelist`; this release applies it to existing databases holding the original seeded value** — the seeder carried its own literal copy of the allowlist, so 0.3.22 changed the compiled default while every seeded database went on granting `curl`, `git`, `ping`, `nslookup`, `cat /proc`, `bin/alex_claw` and bare `ps`. A configured row wins over the compiled default, and the shell tests never caught it because the test database is not seeded
  - The seeder now seeds `Shell.default_whitelist/0`, `default_blocklist/0` and `default_exact_commands/0` rather than second copies. Two tests fail the build if a literal returns, or if a seeded default stops matching the compiled one
  - A migration rewrites `shell.whitelist` where it still holds exactly the originally seeded set, comparing entries as a parsed set so formatting and ordering do not matter. A list an operator has edited is left alone
  - A list left alone that still grants a withdrawn prefix is reported at boot: a logged warning and one gateway notification naming the entries. `shell.blocklist` needed no migration — its seeded value already matched
- **A 2FA challenge cannot be spent guessing** — a challenge accepted any six digits for its full two minutes with no limit on attempts. The third wrong code now cancels it and the action must be triggered again
- **A TOTP code cannot be used twice** — a code is valid for its whole 30-second period, so one observed in transit could be presented again inside that window. `verify/1` passes the last accepted code's time to NimbleTOTP as `since:`. The marker is a settings row, so it survives a restart, and it joins the secret outside the config cache
- **Cross-skill invocation cannot reach privileged core skills** — `SkillAPI.run_skill/3` resolved through the registry, which resolves core skills, and called `run/1` directly. `shell`, `coder`, `db_backup` and `web_automation` are 2FA-gated at the dispatcher and were not passing that gate here. They are now refused by name for every caller and the attempt is recorded as a denial
- **Settings that lie** — eleven seeded settings had no reader, and three skills advertised step fields `run/1` discarded
  - `auth.rate_limit.window_seconds` is wired: the limiter tracked `{ip, attempts, blocked_until}` with no timestamp, so failures never decayed and an IP that failed four times months ago was one attempt from a block. Records now carry the first attempt in their window; failures outside it start a fresh count, and stale records are dropped on check and on purge
  - `rss_collector`, `conversational` and `research` now read the `llm_tier`, `llm_model` and `prompt_template` the executor has always passed them. The step's tier and provider win over the skill-wide default; an unset or unknown value still falls back. RSS scoring keeps `:light` unless the step chooses otherwise
  - Removed, with a migration for existing databases: `llm.limit.{haiku,sonnet,gemini_pro,gemini_flash}` (superseded by `llm_providers.daily_limit`, which is what is enforced), `skill.github_review.{tier,provider}` and `github.security_focus` (that skill fetches diffs and calls no LLM), `discord.guild_id`, `cluster.enabled` (clustering follows registered nodes; the flag defaulted to `false` while clustering worked), and `prompts.rss.scoring` (a per-item template from before scoring became one batched call)
  - `prompts.rss.interests`, `skills.rss.max_items` and `shell.exact_commands` are now seeded. All three were read with a hardcoded fallback and had no UI entry
  - Two source-scan tests fail the build when a key is seeded with no reader, or read with no seed

### Behaviour changes

- **`config_get/3` no longer returns sensitive settings to a skill.** A skill that read an API key out of config must be given the value another way, or granted the capability rather than the credential.
- **`run_skill/3` refuses the four privileged skills.** A workflow that chained into `shell` through another skill must call `shell` as its own step.
- **noVNC is bound to loopback.** `web-automator` published `6080:6080` on every interface, giving unauthenticated browser control to anything on the LAN — which SECURITY.md already said should never be exposed. It now publishes `127.0.0.1:6080:6080`; reach it with `ssh -L 6080:127.0.0.1:6080 <host>`.
- **A shell allowlist seeded before 0.3.26 and never edited is narrowed on migrate.** `curl`, `git`, `ping`, `nslookup`, `cat /proc`, `bin/alex_claw` and bare `ps` stop being accepted by `/shell`. If you relied on any of them, add it back in Admin > Config — deliberately, knowing what it grants.
- **A 2FA challenge is cancelled after three wrong codes**, rather than staying open for the full two minutes.
- **A TOTP code is accepted once.** Re-entering the same code within its 30-second period is refused; wait for the next one.
- **Login failures now expire.** With the default 300-second window, five failures block an IP only if they land inside five minutes. Raise `auth.rate_limit.window_seconds` to restore accumulating behaviour.
- **Workflow steps on `rss_collector`, `conversational` and `research` now honour their tier and provider fields**, which previously had no effect. A step left on a non-default tier will change which model it uses.

## v0.3.25 — Tightening the Containment Envelope (2026-09-19)

Follow-up to 0.3.24, closing gaps in what "contained" actually guaranteed.

- **Permission ceiling for unattended loads** — containment bounds which modules generated code may call, not what `SkillAPI` does for it. An auto-load may now hold only `:llm`, `:web_read`, `:memory_read`, `:knowledge_read`, `:resources_read`, `:gateway_send`
  - `:skill_invoke` excluded: `run_skill/3` resolves core skills and calls `run/1` directly, reaching `shell`, `coder`, `db_backup` and `web_automation`, none of which check 2FA there
  - `:config_read` excluded: settings are decrypted into the ETS cache, so `config_get/3` returns plaintext API keys and the TOTP secret
  - `:web_read` with any private read refused as a pair — read then post is an exfiltration path. `:gateway_send` with a private read stays allowed
  - Anything above the ceiling goes to `pending/` with a TOTP request, and is fed back as a retry hint first
- **Generation cannot take over a name it does not own** — `try_load/2` unconditionally unloaded any skill sharing the derived name before writing. It now refuses unless the existing skill is itself generated and containment-approved; uploaded skills, TOTP-approved generated skills and core names are all protected
- **CallPolicy tightened** — `Logger` limited to its level functions; `List.to_atom/1` and `Jason.decode` with `keys:` other than `:strings` refused; `SweetXml` removed from the generated allowlist (still importable by hand-written skills)
- **Modules never stay resident after vetting** — a skill that compiled but failed its contract check was left loaded, callable by name despite never being registered. `validate_contract/3` now purges on every failure path, and tests assert `:code.is_loaded/1` is false after a contained verdict, a containment failure, a ceiling failure, an AST-gate refusal, a compile error and a contract failure
- **RSS entity handling pinned** — tests assert external, internal and nested entities are never expanded from feed bodies

### Behaviour changes

- **Generated skills declaring permissions above the ceiling no longer auto-load.** They wait in `pending/` for a code. Narrow the declared permissions, or approve deliberately.
- **Generation against an existing non-generated name now fails** instead of replacing it.

## v0.3.24 — Containment for Generated Skills (2026-09-19)

Closes the gap 0.3.23 documented: Coder and Forge loaded LLM-generated code into
the running VM with no second factor, checked only for the `:skill_manage`
permission.

- **Generated code is staged and judged before it loads** — generation writes to `<skills_dir>/pending/`, never the live directory. `AlexClaw.Skills.CallPolicy` then checks every remote call in the source against an allowlist
  - Contained code loads with no 2FA code, recorded as approval `containment`
  - Anything else has its violations fed back to the model as a retry hint naming the calls to replace
  - If it still will not fit, the file stays staged and a TOTP challenge is raised listing the offending calls; approval loads it as `totp`, and an unconfigured 2FA refuses it
- **Containment is re-judged on every boot** for skills approved that way, so an allowlist tightened in a release takes effect. `SkillRegistry.reload_persisted/0` applies it on demand. Skills approved by a code are not re-judged
- **Provenance recorded** — `dynamic_skills` gains `origin` ("upload" | "generated") and `approval` ("totp" | "containment"); existing rows backfill to upload/totp
- **`validate_runtime/1` runs generated code through `SafeExecutor`** with a timeout instead of calling `run/1` in the caller's process, and only ever for contained code
- **`SkillRegistry.describe_error/1`** — one formatter for load failures, used by the Skills page, Forge and the gateway reply. Restores the readable messages lost with `load_message/1` in 0.3.23 and covers the failures added since

Hand-written uploads are unchanged: their boundary is still the TOTP code on upload.

### Behaviour changes

- **Generated skills that call outside the allowlist no longer load automatically.** They wait in `pending/` for a 2FA code. Rewrite them against `SkillAPI`, or approve them deliberately.
- **A containment-approved skill that no longer passes the check will not load on boot**, and is reported over the gateway. This can happen after an upgrade that tightens the allowlist.

## v0.3.23 — Documentation Accuracy and Budget Wiring (2026-09-19)

Follow-up to 0.3.22. Corrects security documentation that described protections
the code does not provide, and wires a setting that never took effect.

- **Coder and Forge load generated code without 2FA** — documented plainly in SECURITY.md. `/coder` and the Forge page generate a skill with a local LLM and load it into the running VM immediately, checked only for the `:skill_manage` permission. Every other route to loading a skill is 2FA-gated; these are not. The section names the two lines to remove for deployments where that is unacceptable — there is no runtime toggle
- **Skill commands are available from the gateway** — SECURITY.md claimed skill management was "Admin UI only" and that `/skill load|unload|reload` were unavailable from Telegram/Discord. All three have always been dispatched there, 2FA-gated. The gateway names a file already in the skills volume; code still cannot be uploaded from a messaging app
- **`reasoning.time_budget_seconds` now takes effect** — `config.time_budget_ms` was computed and never read, so both timers were hardcoded. The per-step figure still rescales the budget to the plan; the configured value is now the ceiling it may not exceed, matching the documented "maximum wall-clock time"
- **Removed the unreachable post-2FA execution path** in `Dispatcher.SkillCommands` — roughly 90 lines whose only entry points were three wrappers nothing called. `AuthCommands.execute_2fa_action/2` has always done this work

### Behaviour changes

- **Plans of three or more steps now stop at `reasoning.time_budget_seconds`** (default 900s) where they previously ran to `steps * 300s + 60s`. Raise the setting if longer plans need the time.

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
