# Security Policy

## Reporting a Vulnerability

Please do NOT open a public GitHub issue for security vulnerabilities.

Contact: development@securtel.net
Expected response: within 72 hours
Coordinated disclosure: 90 days before public disclosure requested

---

## Authentication

AlexClaw includes built-in session-based authentication. The web interface
is fully protected — all routes except `/login` require an authenticated session.
There is no anonymous access to any admin functionality.

Authentication is configured via the `ADMIN_PASSWORD` environment variable
(see `.env.example`). `ADMIN_PASSWORD` is always required — if it is not set,
the login page will show an error and no access is granted.

---

## Two-Factor Authentication

TOTP-based 2FA protects all sensitive operations. Setup via `/setup 2fa`
from Telegram or Discord — compatible with any TOTP authenticator
(Google Authenticator, Authy, etc.).

**Operations requiring 2FA (mandatory, no bypass):**
- **Skill load** — uploading and compiling a new dynamic skill (Admin UI only)
- **Skill unload** — removing a dynamic skill from the registry (Admin UI only)
- **Skill reload** — recompiling an existing dynamic skill (Admin UI only)
- **Shell commands** — `/shell` via Telegram/Discord
- **Workflows marked `Requires 2FA`** — configurable per workflow

**Cross-channel verification:** When a skill operation is triggered from the
Admin UI, the 2FA challenge is sent to ALL active gateways (Telegram and
Discord). The user can respond with their 6-digit code from either channel.
This enables phone-based verification for web UI actions.

**Skill management is Admin UI only.** The `/skill load|unload|reload`
commands are not available from Telegram/Discord — you cannot upload code
from a messaging app. The `/skills` command still lists registered skills,
and skills execute normally within workflows.

---

## Telegram Gateway Security

AlexClaw only responds to messages from the configured `TELEGRAM_CHAT_ID`.
Messages from any other chat ID are silently ignored.
Do not share your bot token — anyone with the token can send commands
if they know or guess your chat ID.

---

## GitHub Webhook Verification

The `/webhooks/github` endpoint verifies all incoming payloads using
HMAC-SHA256 with `Plug.Crypto.secure_compare` for timing-safe comparison.
Webhooks without a valid signature are rejected with 401.
If no webhook secret is configured, all webhooks are rejected.
Set `github.webhook_secret` in Admin > Config (GitHub category).

---

## MCP Server Authentication

The MCP endpoint (`/mcp`) exposes AlexClaw skills, workflows, and data to external AI clients (Claude Code, Cursor, Claude Desktop) via the Model Context Protocol.

**Bearer token auth:** Every MCP request must include `Authorization: Bearer <token>`. The token is validated against `mcp.api_key` stored in Admin > Config using `Plug.Crypto.secure_compare/2` (constant-time comparison, no timing attacks). Requests without a valid token receive 401.

**Token management:**
- Store the API key encrypted in PostgreSQL (`sensitive: true` on the config setting)
- No automatic expiration — treat MCP tokens like long-lived API keys
- Rotate by updating `mcp.api_key` in Admin > Config — all previous tokens are immediately invalidated
- If compromised: rotate immediately in Admin > Config

**Policy enforcement:** MCP tool calls pass through `PolicyEngine.evaluate/2` with `:mcp` caller type. The `mcp_restriction` policy rule type blocks tools by name pattern — insert a policy with `rule_type: "mcp_restriction"` and `config: {"tool_pattern": "shell", "action": "deny"}` to block any tool matching that pattern.

**Resource filtering:** Sensitive config values (API keys, OAuth tokens) are redacted in MCP resource responses — only `[REDACTED]` is returned for settings marked `sensitive: true`.

**Audit logging:** All MCP tool invocations are logged to `auth_audit_log` with caller `mcp:<tool_name>`, visible in Admin > Policies > Audit Log.

**Hardening recommendations:**
- The `/mcp` endpoint must be behind TLS — never transmit Bearer tokens over plain HTTP
- Store the MCP API key in your client's config securely (environment variable or encrypted config)
- Monitor the Audit Log for unexpected MCP activity
- Use `mcp_restriction` policies to limit which tools are available to MCP clients
- If MCP is not needed, do not set `mcp.api_key` — the auth plug rejects all requests when the key is unconfigured

---

## Inter-Node Authentication (Clustering)

Multi-node clusters authenticate via BEAM's distributed Erlang protocol:

- All nodes must share the same `CLUSTER_COOKIE` (set via environment variable)
- EPMD (Erlang Port Mapper Daemon) on port 4369 coordinates node discovery
- Nodes without the correct cookie cannot join the cluster or trigger remote workflows
- The `receive_from_workflow` gate skill provides an additional per-workflow access control layer via optional `allowed_nodes` config

**Hardening recommendations:**
- Generate `CLUSTER_COOKIE` with `openssl rand -base64 32` — treat it like `SECRET_KEY_BASE`
- EPMD port (4369) and BEAM distribution ports (dynamic, high range) should NOT be exposed to the internet
- Restrict inter-node traffic to private networks, VPCs, or Docker networks
- When running across machines, use VPN or SSH tunnels between Docker hosts

---

## Shell Skill (Container Introspection)

The `/shell` command allows the owner to run OS commands inside the container
for diagnostics (disk, memory, connectivity, BEAM status). It is protected
by 5 layers of defense-in-depth:

1. **Disabled by default** — `shell.enabled` must be explicitly set to `true` in Admin > Config. The check is enforced both in the Dispatcher and inside the skill itself.
2. **2FA gate** — every `/shell` command requires TOTP verification when 2FA is enabled.
3. **Whitelist with word-boundary check** — the command must start with an allowed prefix (`df`, `free`, `ps`, `uptime`, `git`, etc.). The prefix is boundary-checked: `"df"` allows `"df -h"` but not `"define"`. The whitelist is stored as a JSON array in the database and editable from Admin > Config.
4. **Blocklist** — commands containing shell metacharacters (`&&`, `||`, `|`, `;`, `` ` ``, `$(`, `>`, `<`, `\n`) are rejected even if the prefix is whitelisted.
5. **No shell interpretation** — commands are executed via `System.cmd/3` with arguments passed as a list (parsed by `OptionParser.split/1`). No shell is invoked — no globbing, no piping, no variable expansion.

Additional protections:
- **Timeout** — commands are killed after 30 seconds (configurable via `shell.timeout_seconds`)
- **Output truncation** — output is capped at 4000 characters (configurable via `shell.max_output_chars`)
- **Workflow mode** — when used in workflows, the command comes from step config (not user input), preventing injection through workflow chaining

---

## Web Automator Sidecar

The web-automator sidecar runs a real browser with network access.
Automation recipes execute arbitrary browser actions — review recorded
recipes before assigning them to scheduled workflows.
The noVNC interface (port 6080) should never be exposed publicly.

---

## Database Backups

The `db_backup` core skill produces gzip-compressed `pg_dump` files on a
host-mounted directory. Backups contain the **full database contents**
including encrypted API keys and tokens (stored as AES-256-GCM ciphertext).

**Security considerations:**
- Backup files should be stored on an encrypted filesystem or encrypted at
  the host level — the `pg_dump` output contains encrypted values but also
  plaintext data (workflows, memories, knowledge entries, settings metadata)
- Restrict host directory permissions (`chmod 700`) to prevent unauthorized access
- The skill verifies the backup directory is a real bind mount, not the
  container overlay FS — this prevents backups from being silently lost on
  container recreation
- Backup rotation (configurable `backup.max_files`) limits exposure window —
  old backups are deleted automatically
- To restore: `gunzip -c backup.sql.gz | psql -U alexclaw -d alex_claw_prod`
  from a host with access to the database

---

## Encryption at Rest

Sensitive configuration values (API keys, tokens, OAuth secrets) are encrypted
at the application level using **AES-256-GCM** before being stored in PostgreSQL.

- Encryption key is derived from `SECRET_KEY_BASE` via HKDF-SHA256
- Each value gets a unique 12-byte random IV — identical plaintext produces different ciphertext
- Encrypted values are stored with an `enc:` prefix (base64-encoded IV + ciphertext + GCM tag)
- Decryption happens transparently on boot (ETS cache holds plaintext for runtime use)
- The admin UI displays masked values — never raw ciphertext or full plaintext

**Sensitive keys** (automatically marked and encrypted):
`telegram.bot_token`, `llm.gemini_api_key`, `llm.anthropic_api_key`,
`github.token`, `github.webhook_secret`, `google.oauth.client_secret`,
`google.oauth.refresh_token`

**Important:** If you change `SECRET_KEY_BASE`, all encrypted settings become
unreadable. You will need to re-enter API keys and tokens via the admin UI
or environment variables and restart.

---

## Dynamic Skill Loading

Dynamic skills are compiled into the BEAM VM at runtime via `Code.compile_file`.
The following protections are in place:

- **2FA mandatory** — every load, unload, and reload requires TOTP verification via Telegram/Discord. No exceptions, no config toggle
- **Admin UI only** — skill management is not available from Telegram/Discord commands. Code cannot be uploaded from a messaging app
- **Version bump enforcement** — loading a skill that's already loaded with the same version is rejected. The developer must bump `version/0` or use reload to force
- **Path restriction** — only files inside the configured `SKILLS_DIR` volume are accepted
- **Namespace enforcement** — module must be `AlexClaw.Skills.Dynamic.*`
- **Behaviour validation** — module must export `run/1`
- **Permission sandbox** — skills declare permissions; `SkillAPI` enforces them at runtime. Undeclared permissions return `{:error, :permission_denied}`
- **Integrity checksums** — SHA256 of source file stored on load, verified on boot. Mismatched files are skipped
- **Core protection** — core skills cannot be unloaded or overwritten by dynamic skills
- **No NIF compilation** — the Alpine runtime image has no build tools, preventing native code loading
- **External skill detection (AST-based)** — at load time, dynamic skill source is AST-scanned for calls to HTTP/socket libraries (Req, HTTPoison, Finch, Tesla, `:gen_tcp`, `:httpc`, SkillAPI.http_*). If detected without `def external, do: true`, the skill is **rejected** (fail-closed). This prevents untagged dynamic skills from fetching external data without proper sanitization. Note: this scan is single-module only — indirect calls through helper modules are not caught in v1

**Circuit breaker protection:** Each skill (core and dynamic) is wrapped by an
OTP circuit breaker. After 3 consecutive failures, the circuit opens and calls
are rejected instantly without executing the skill. This prevents a failing
dynamic skill from consuming resources or cascading failures through workflows.
Workflow steps can be configured to skip or fallback to an alternative skill
when a circuit is open or a skill is missing.

**Autonomous Skill Generation (Coder Skill):**
The `/coder` command uses a local LLM to generate dynamic skills from natural
language descriptions. Generated code passes through the same validation pipeline
as manually-loaded skills (namespace, behaviour, permission checks). Additional
safety measures:
- Filename validation rejects path traversal (`..`, `/`, `\`)
- Only `.ex` files can be written
- Writes are confined to the configured skills directory
- Generated workflows are created in disabled state
- All generated code is logged via `Logger.info` for audit
- Always uses `tier: :local` — zero cloud API cost
- Retry bound prevents infinite loops (configurable, default 3)

**What is NOT sandboxed:** A dynamic skill runs in the same BEAM VM as the rest
of AlexClaw. A malicious skill could bypass SkillAPI by calling internal modules
directly. The permission system is a guardrail, not a security boundary.
Only load skills from sources you trust.

---

## Content Sanitization (Prompt Injection Defense)

External-facing skills (`web_search`, `web_browse`, `api_request`, `rss_collector`,
`github_security_review`, `google_calendar`, `google_tasks`, `web_automation`,
`research`) fetch data from untrusted sources. This data flows through the
workflow engine and may reach the LLM, creating a prompt injection surface.

**External skill tagging:** Skills that fetch external data declare
`def external, do: true` (callback on `AlexClaw.Skill` behaviour). The
`SkillRegistry` tracks this flag in ETS and exposes `external?/1` for
runtime checks.

**7-layer heuristic sanitizer (`AlexClaw.ContentSanitizer`):**

Content from external skills passes through 7 defense layers before reaching
the LLM:

1. **Hidden HTML detection** — detects and logs content in `<noscript>`,
   `<template>`, `aria-hidden="true"` elements before stripping
2. **Hidden CSS detection** — detects and logs content with `display:none`,
   `visibility:hidden`, `font-size:0`, `color:transparent`, `opacity:0`,
   off-screen positioning (`left:-9999px`), `text-indent:-9999px`, `clip:rect(0...)`
3. **Zero-width unicode stripping** — removes 19 types of invisible characters
   used for steganographic injection (`U+200B` through `U+180E`, `U+FEFF`, etc.)
4. **HTML stripping** — Floki-based extraction of semantic text only (script,
   style, noscript, template, meta, head, svg removed)
5. **Size guard** — configurable max content size (default 10KB), truncates oversized payloads
6. **Pattern matching** — 101 known injection phrases loaded from
   `config/injection_patterns.json` at runtime (updatable without recompilation).
   Patterns sourced from NVIDIA Garak probe library covering DAN, developer mode,
   instruction override, persona hijacking, token penalty, encoding tricks, and more
7. **Imperative tone heuristic** — detects directive language (second-person
   pronouns + imperative verbs like "ignore", "forget", "obey", "execute",
   "reveal") to catch novel payloads not in the pattern list

**Pre-LLM sanitization:** `web_browse` and `web_search` sanitize fetched
content before building the LLM prompt. Injection payloads are stripped
before the model ever sees them.

**Post-LLM sanitization:** The workflow executor auto-sanitizes output from
any skill tagged `external?/1 == true`, catching skill name leaks or
residual injection artifacts in the LLM response.

**Stripped sentences are logged** with their detection reason (`[pattern]`,
`[imperative]`, `[skill_mention]`) for forensic analysis.

**Known limitations:**
- Pattern matching cannot catch novel injection techniques not in the JSON file
- The imperative tone heuristic may produce false positives on legitimate
  directive text (e.g., "Experts recommend..." is preserved, but edge cases exist)
- Encoding-based attacks (Base64, ROT13) bypass pattern matching — the encoded
  payload reaches the LLM, though most models don't decode and follow them
- Future: embedded tiny classifier model (Qwen2.5-0.5B / SmolLM2-360M) for
  binary injection classification as a second pass on ambiguous sentences

---

## Agent Authorization Layer

AlexClaw implements a composable authorization layer for skill execution,
inspired by Macaroon-style capability tokens and policy-as-code evaluation.

**Context-aware permission checks:**
Every `SkillAPI` call builds an `AuthContext` (caller, type, permission,
chain depth, workflow run ID, timestamp) and evaluates it through the
`PolicyEngine`. Core skills bypass all checks (trusted code). Dynamic
skills are checked against their declared permissions, capability tokens,
and active policy rules.

**Capability tokens (Macaroon-style):**
When a workflow executes, each step receives an HMAC-signed capability
token scoped to the skill's declared permissions. Cross-skill invocation
via `run_skill/3` attenuates the token — a child skill can only receive
a subset of the caller's permissions, never more. Tokens are signed
with a key derived from `SECRET_KEY_BASE` via HKDF-SHA256.

**Chain depth enforcement:**
Skill-invokes-skill chains are limited to depth 3 (configurable).
Prevents infinite recursion and limits blast radius of cross-skill calls.

**Process isolation for dynamic skills:**
Dynamic skills run in a separate spawned process (`SafeExecutor`).
The capability token is set in the child's process dictionary, isolating
it from the caller. Core skills run in-process (no overhead).

**Policy rules (configurable via Admin > Policies):**

All policy configs are JSON objects. The `permission` field is optional —
omit it to apply the rule to all permissions. Higher `priority` rules
are evaluated first.

**`rate_limit`** — max N calls per time window per skill/permission.
```json
{"permission": "llm", "max_calls": 20, "window_seconds": 60}
```
Blocks the skill after 20 LLM calls within 60 seconds. Omit `permission`
to limit all SkillAPI calls globally. Counters are per-skill, in-memory
(reset on restart).

**`time_window`** — deny a permission during specific UTC hours.
```json
{"permission": "web_read", "deny_start_hour": 0, "deny_end_hour": 6}
```
Blocks `web_read` between 00:00 and 06:00 UTC. Useful to prevent
scheduled workflows from hitting external APIs during maintenance windows.

**`chain_restriction`** — prevent a skill from invoking other skills.
```json
{"caller_pattern": "Coder"}
```
Any skill whose module name contains "Coder" will be denied when it
tries to invoke another skill via `run_skill/3` (chain_depth > 0).
The pattern is a substring match on the full module name.

**`permission_override`** — temporarily deny (or allow) a specific permission.
```json
{"permission": "memory_write", "action": "deny", "expires_at": "2026-04-01T00:00:00Z"}
```
Denies `memory_write` for all dynamic skills until the expiry date.
Omit `expires_at` for a permanent override. Set `action` to `"deny"`
to block — any other value (or omitting it) has no effect.

Policies are stored in PostgreSQL, cached in ETS (30s TTL), and
manageable from Admin > Policies. Changes take effect within 30 seconds.

**Audit logging:**
All authorization denials are persisted to the `auth_audit_log` table
with full context (caller, permission, reason, chain depth, workflow run).
Viewable from Admin > Policies > Audit Log. Auto-pruned after 30 days.

**Limitation:** A malicious dynamic skill can still bypass SkillAPI by
calling internal modules directly. The authorization layer is enforcement
at the API boundary, not a sandbox. Only load skills from trusted sources.

---

## Known Limitations and Design Decisions

**LLM prompts may contain user data.**
Workflow steps send data to external LLM providers (Anthropic, Google Gemini).
Review which providers are enabled and their data retention policies before
processing sensitive information.

**Built-in login rate limiting.**
Failed login attempts are tracked per IP using ETS. After 5 failures
(configurable), the IP is blocked for 15 minutes (configurable).
Limits are adjustable at runtime from the Config UI without restart.

---

## Deployment Hardening

- Run behind a reverse proxy with TLS — never expose port 5001 directly
- Set a strong random `SECRET_KEY_BASE` (`mix phx.gen.secret`) — this is also the encryption key material for sensitive config values
- Set `ADMIN_PASSWORD` to a strong random value
- Restrict PostgreSQL to localhost or internal network only
- Built-in login rate limiting is active by default (configurable via Config UI)
- Never expose noVNC port (6080) publicly — it provides unauthenticated browser access

---

## Scope

AlexClaw is designed as a single-user personal agent. Multi-user access
control is not in scope. The authentication model assumes a single trusted
operator.
