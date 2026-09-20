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

## Control-Plane Elevation

The admin password authenticates a session. It does not, on its own, authorise
a change to what the agent does unattended.

Changing the control plane — configuration, authorization policies, LLM
providers, API resources, cluster membership, workflows and their steps —
requires an **elevation** on top of the session: one TOTP code, verified once,
granting fifteen minutes of write authority to that session alone.

**The window is fixed.** It does not slide with activity. Fifteen minutes after
the code was accepted the session is read-only again, whether it was idle or in
use, so an open tab is never a standing grant.

**Elevation is per session.** It is keyed by a random identifier placed in the
session at login and dropped at logout. One browser's unlock says nothing about
another's. Only a fingerprint of that identifier reaches the audit log or a
PubSub topic; the identifier itself is a live credential and is never written
anywhere durable.

**Checks are server-side.** A control-plane event is refused in its handler, not
by hiding a button, and a refused event leaves the database untouched. Both the
write and the refusal are recorded in the authorization audit log, naming the
session by fingerprint, the key or record touched, and its old and new values —
with sensitive values masked, because the record worth keeping is that a secret
changed and who changed it.

### What elevation does not cover

**Database restore is challenged every time.** Restoring an uploaded SQL file
runs arbitrary SQL against the live database as the application's own user,
which reaches the settings and policy tables without passing through either. It
therefore asks for a code per restore and is never covered by an existing
elevation: authority earned for editing a setting is not authority to replace
the database. The upload is staged on disk while the code is outstanding, and
discarded whether the restore runs or not.

**Running a workflow follows the workflow's own rule.** A workflow marked
`requires_2fa` is challenged when it is run, from the Workflows page and the
Scheduler page alike. Editing a workflow is a control-plane change and needs an
elevation; running it is governed by the flag.

**Scheduled runs are not challenged.** A schedule is authorised when it is
saved, under elevation. The run that follows is the schedule doing what it was
told to do.

### auth.totp.* is managed from a gateway

The `auth.totp.*` settings are not editable from the Config page at any
elevation, and deleting them is refused for the same reason as changing them.
They are written by `/setup 2fa` and `/disable 2fa` on a gateway, and nowhere
else.

This is load-bearing rather than tidy. Whether elevation is enforced at all is
decided by `auth.totp.enabled`; if that setting were editable from behind the
gate it protects, a session could switch the gate off and then change anything.

### Without a second factor

With no TOTP configured there is nothing to verify, so elevation is not
enforced: writes proceed under the admin password alone, and every gated page
carries a banner saying exactly that. Those writes are still audited, and marked
as having had no second factor.

This is the bootstrap case — an instance has to be configurable before 2FA can
be set up on it. It is also the weakest state the admin UI can be in, and the
banner exists so that state is never mistaken for a guarded one.

---

## Two-Factor Authentication

TOTP-based 2FA protects all sensitive operations. Setup via `/setup 2fa`
from Telegram or Discord — compatible with any TOTP authenticator
(Google Authenticator, Authy, etc.).

**Operations requiring 2FA (mandatory, no bypass):**
- **Skill load** — uploading and compiling a new dynamic skill (Admin UI or `/skill load`)
- **Skill unload** — removing a dynamic skill from the registry (Admin UI or `/skill unload`)
- **Skill reload** — recompiling an existing dynamic skill (Admin UI or `/skill reload`)
- **Shell commands** — `/shell` via Telegram/Discord
- **Workflows marked `Requires 2FA`** — configurable per workflow

**Attempt limit.** A challenge lives for two minutes and accepts any six digits
in that time. Without a bound those two minutes are a guessing window, and the
gateway will deliver as many messages as it is sent. The challenge carries its
attempt count: the third wrong code deletes it, and the action must be
triggered again, which mints a fresh challenge.

**Replay protection.** A code stays valid for its whole 30-second period, so one
observed in transit could be presented a second time inside that window.
`verify/1` passes the time of the last accepted code to `NimbleTOTP.valid?/3`
as `since:`, which refuses any code from a period already used. The marker is a
settings row rather than an ETS entry, so it survives a restart, and it is kept
out of the config cache with the secret.

**Not every privileged route is a 2FA prompt.** The four privileged core skills
— `shell`, `coder`, `db_backup`, `web_automation` — are gated by 2FA when they
are dispatched from a gateway command. Invoked from inside another skill through
`SkillAPI.run_skill/3` they were not passing that gate, so that call is refused
outright rather than challenged: there is no interactive user to prompt on a
workflow step or a reasoning-loop iteration.

**Cross-channel verification:** When a skill operation is triggered from the
Admin UI, the 2FA challenge is sent to ALL active gateways (Telegram and
Discord). The user can respond with their 6-digit code from either channel.
This enables phone-based verification for web UI actions.

**Skill management is available from Telegram/Discord**, via
`/skill load|unload|reload`, and every one of them is 2FA-gated: the command
raises a TOTP challenge and is refused outright when 2FA is not configured. The
file must already be inside the skills volume — the gateway names a file, it
does not carry code. The `/skills` command still lists registered skills,
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
3. **Allowlist with word-boundary check** — the command must either match an exact allowed command byte-for-byte, or start with an allowed prefix (`df`, `free`, `uptime`, `uname`, `whoami`, `hostname`, `date`, `ls`). The prefix is boundary-checked: `"df"` allows `"df -h"` but not `"define"`. Commands that are safe only in one exact form live in `shell.exact_commands` (default: `cat /proc/meminfo`, `cat /proc/loadavg`, `ps aux`) — `ps aux` is permitted while `ps eww`, which prints other processes' environments, is not.
4. **Blocklist** — commands containing shell metacharacters (`&&`, `||`, `|`, `;`, `` ` ``, `$(`, `>`, `<`, `\n`) are rejected even if the prefix is allowed.
5. **No shell interpretation** — commands are executed via `System.cmd/3` with arguments passed as a list (parsed by `OptionParser.split/1`). No shell is invoked — no globbing, no piping, no variable expansion.

The allowlist, exact-command list and blocklist are read from Config or the
compiled defaults **only**. A workflow step supplies a command, never the rules
it is checked against.

**A configured list wins over the compiled default**, which is why the seeded
copy matters. Until 0.3.26 the seeder carried its own literal allowlist, so the
narrowing in 0.3.22 changed the compiled default while every seeded database
kept granting `curl`, `git`, `ping`, `nslookup`, `cat /proc`, `bin/alex_claw`
and bare `ps`. The seeder now seeds `Shell.default_whitelist/0` itself rather
than a second copy, and a test fails the build if a literal returns.

For databases already seeded, 0.3.26 rewrites `shell.whitelist` where it still
holds exactly the originally seeded set. A list that has been edited is left
alone — the allowlist decides what runs in the container, and that is the
operator's call, not a migration's. When a list is left alone and still grants
a withdrawn prefix, `Config.Loader` logs a warning at boot and sends one
gateway notification naming the entries.

Additional protections:
- **Timeout** — commands are killed after 30 seconds (configurable via `shell.timeout_seconds`)
- **Output truncation** — output is capped at 4000 characters (configurable via `shell.max_output_chars`)
- **Limits can be narrowed, never widened** — a step may pass a smaller `timeout_seconds` or `max_output_chars`, but values above the configured ceiling are clamped to it, and non-positive values are ignored
- **Workflow mode** — when used in workflows, the command comes from step config (not user input), preventing injection through workflow chaining

**The 2FA gate is the boundary, and it is only as strong as the gateway.** `/shell`
is refused outright when TOTP is not configured, rather than running unprotected.
Verification happens over Telegram or Discord, so anyone who controls the
configured chat can approve a shell command.

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
- Decryption happens transparently on boot (the ETS cache holds plaintext for runtime use)
- The admin UI displays masked values — never raw ciphertext or full plaintext
- The TOTP secret is excluded from the cache: `auth.totp.secret` is read from the row and decrypted per verification, so `Config.get/2` never serves it and its plaintext exists only for the length of a check
- Every cached row carries its `sensitive` flag alongside its value, and `SkillAPI.config_get/3` refuses any key marked sensitive rather than returning the plaintext. A key the cache does not know is treated as sensitive

**Sensitive keys** (automatically marked and encrypted):
`telegram.bot_token`, `llm.gemini_api_key`, `llm.anthropic_api_key`,
`github.token`, `github.webhook_secret`, `google.oauth.client_secret`,
`google.oauth.refresh_token`

**Important:** If you change `SECRET_KEY_BASE`, all encrypted settings become
unreadable. You will need to re-enter API keys and tokens via the admin UI
or environment variables and restart.

---

## Dynamic Skill Loading

Dynamic skills are compiled into the BEAM VM at runtime. The source is parsed
and vetted as a syntax tree **before** anything is compiled, because compiling a
module runs its body. The following protections are in place:

- **2FA on every manual load** — load, unload and reload require TOTP verification via Telegram/Discord, from both the Admin UI and the `/skill` commands, and are refused when 2FA is not configured. Skills generated by Coder/Forge are gated by containment instead, and fall back to the same TOTP challenge when they leave the contained set — see below
- **Available from the Admin UI and the gateway** — `/skill load|unload|reload` work from Telegram/Discord, 2FA-gated. The gateway names a file already present in the skills volume; code itself cannot be uploaded from a messaging app
- **Version bump enforcement** — loading a skill that's already loaded with the same version is rejected. The developer must bump `version/0` or use reload to force
- **Path restriction** — only files inside the configured `SKILLS_DIR` volume are accepted
- **One module per file** — the file's top level must be exactly one `defmodule` and nothing else. A file carrying a second module could previously replace a core module such as `AlexClaw.Auth.PolicyEngine` in the running VM, and a statement outside the module ran at compile time
- **Namespace enforcement** — module must be `AlexClaw.Skills.Dynamic.*`, checked on the syntax tree before compiling
- **No compile-time execution** — the module body is limited to `def`, `defp`, `@`, `alias`, `require` and `import`. Attributes must be literals or `~w`/`~s`/`~r` sigils; `@on_load`, `@after_compile`, `@before_compile`, `@on_definition`, `@compile`, `use`, and `unquote` are rejected
- **Restricted compile-time dependencies** — `import` and `require` are limited to `Logger`, `AlexClaw.Skills.Helpers` and `SweetXml`, anywhere in the file. Both bring macros into scope, and a macro expands at compile time wherever it is called, including inside a function body
- **Behaviour validation** — module must export `run/1`
- **Permission sandbox** — skills declare permissions; `SkillAPI` enforces them at runtime. Undeclared permissions return `{:error, :permission_denied}`
- **Privileged skills are unreachable from another skill** — `SkillAPI.run_skill/3` refuses `shell`, `coder`, `db_backup` and `web_automation` for every caller, dynamic or core, and logs the attempt as a denial. Those four are 2FA-gated at the dispatcher; called skill-to-skill they were not passing that gate, so the route is closed rather than gated
- **Secrets do not reach skills** — `SkillAPI.config_get/3` returns `{:error, :sensitive}` for any setting marked sensitive, and for any key the config cache does not know. `SkillAPI.list_resources/2` and `get_resource/2` drop `metadata["auth"]` and strip userinfo from the resource URL
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

**Autonomous Skill Generation (Coder skill and the Forge page):**

`/coder` and the Forge admin page generate a skill with a local LLM. What happens
next depends on what the generated code calls.

**Contained code loads without a 2FA code.** After generation the source is
staged in `<skills_dir>/pending/`, compiled far enough to be read, and checked by
`AlexClaw.Skills.CallPolicy`. A skill is *contained* when every remote call it
makes resolves to one of:

> `SkillAPI`, `Skills.Helpers`, `Enum`, `Map`, `MapSet`, `List`, `Keyword`,
> `Tuple`, `Stream`, `Range`, `Access`, `String`, `Integer`, `Float`, `Regex`,
> `Jason`, `Base`, `URI`, `Path`, `Date`, `Time`, `DateTime`, `NaiveDateTime`,
> `Logger`, `SweetXml`, `Floki`, `:math`

plus calls to itself. `Logger` is limited to its level functions, since it also
carries configuration and backend control. Refused: dynamic dispatch (a module in
a variable, `apply/2`, `apply/3`), `spawn`, `send`, atom creation from runtime
data (`String.to_atom/1`, `List.to_atom/1`, `Jason.decode` with any `keys:` other
than `:strings`), and any alias form that cannot be resolved statically
(`alias ..., as:`, `A.{B, C}`). `SweetXml` is deliberately absent: it is
macro-heavy and its parse options decide entity handling, which this checker
cannot inspect — hand-written skills may still import it.

**The permissions it declares are capped too.** Containment bounds which modules
the code may call; it cannot bound what `SkillAPI` does on the skill's behalf,
and the permissions were written by the same model that wrote the code. An
unattended load may hold only `:llm`, `:web_read`, `:memory_read`,
`:knowledge_read`, `:resources_read` and `:gateway_send`.

Two exclusions are worth spelling out, and both are now defended twice.
`:skill_invoke` reached core skills: `SkillAPI.run_skill/3` resolves through the
registry, which resolves core skills, and calls `run/1` directly — a route to
`shell`, `coder`, `db_backup` and `web_automation`, none of which check 2FA
inside `run/1`. `run_skill/3` now refuses those four by name for any caller and
records the attempt as a denial, so the ceiling is no longer the only thing
standing between a generated skill and a shell. `:config_read` read secrets:
settings are decrypted into the ETS cache, so `config_get/3` returned plaintext
API keys. It now refuses any key marked sensitive, and the TOTP secret is not
cached at all.

The ceiling keeps both exclusions regardless. A permission that is only safe
because of a second check is not a permission an unattended load should hold.

`:web_read` together with any of the private reads is refused as a pair even
though each is allowed alone — read and then post is an exfiltration path.
`:gateway_send` with a private read stays allowed, because that output goes to
the configured chat rather than anywhere the skill chooses.

`:resources_read` is inside the ceiling, and a resource row carries the
credential its requests are made with: `api_request` reads
`metadata["auth"]["value"]`, and a feed URL may embed userinfo. `SkillAPI`
therefore drops the `auth` key from resource metadata and strips userinfo from
resource URLs before returning either. A skill can still name a resource and ask
for a request against it; it cannot read the credential out.

Contained code within the ceiling is promoted out of `pending/` and loaded with
approval `containment`.

**Generation cannot take over a name it does not own.** A generated skill may
replace another generated skill that was approved by containment, and nothing
else. An uploaded skill, a generated skill approved by a TOTP code, and a core
skill name are all refused — otherwise a goal whose derived name happened to
collide would quietly replace a skill somebody had approved.

**Anything else waits for a code.** The violations are fed back to the model as a
retry hint naming the calls to replace. If it still cannot get inside the
envelope, the file stays in `pending/`, a TOTP challenge is raised listing the
offending calls, and the skill loads only once a code is verified — recorded then
as approval `totp`. With 2FA unconfigured the skill is refused and left staged.

**Containment is re-checked on every boot**, for skills approved that way. The
allowlist can tighten between releases, and a skill nobody ever approved should
not keep running on a verdict that no longer holds. Skills approved by a code are
not re-judged.

**What containment is not.** It is static analysis of direct calls in one file.
The allowed modules are still real code: `SkillAPI` genuinely acts on the skill's
behalf — within the permissions the skill declared, which the model also wrote —
and `Logger` genuinely writes to the logs. Containment bounds *what a generated
skill can reach*, not what it can do with what it reaches. A contained skill can
still exfiltrate through `SkillAPI.http_get/3` if it holds `:web_read`, and can
still write nonsense to memory if it holds `:memory_write`. Review the
permissions on generated skills, and treat the local model producing them as part
of the trust boundary — a `/coder` goal can arrive as a gateway message.

The generated code additionally passes the same load-time validation as a
hand-written skill (one module per file, namespace, module body restrictions,
behaviour, permission checks). Other safety measures:
- Filename validation rejects path traversal (`..`, `/`, `\`)
- Only `.ex` files can be written
- Writes are confined to `<skills_dir>/pending/` until the skill is approved
- Generated workflows are created in disabled state
- All generated code is logged via `Logger.info` for audit
- `/coder` always requests `tier: :local` — zero cloud API cost. **Forge does not**: its provider selector lists every configured provider, so generation can be routed to a cloud model. The default is local. Choosing otherwise puts a third party in the loop for code that will be compiled into the running VM, and widens the trust boundary described above beyond the local model
- Retry bound prevents infinite loops (configurable, default 3)
- `run/1` is exercised through `SafeExecutor` with a timeout during validation, never called directly, and only for contained code

**What is NOT sandboxed:** the load-time checks stop code running while a skill
is *loaded*. They do not constrain what `run/1` does once the skill is invoked.

For a **hand-written** skill there is no call restriction at all: it runs in the
same BEAM VM as the rest of AlexClaw, with full VM privileges, and can call
`File`, `System`, `:os` or `AlexClaw.Repo` directly, reaching any internal module
without going through `SkillAPI`. Its boundary is the TOTP code someone entered
to load it.

For a **generated** skill, `CallPolicy` restricts which modules the source may
call — but only by static analysis of direct calls, and only for code approved by
containment. A generated skill approved by a TOTP code instead carries no such
restriction, exactly like a hand-written one.

**The permissions a skill declares are an API contract, not a sandbox.** They
determine what `SkillAPI` will do on the skill's behalf; they cannot stop a
skill that ignores `SkillAPI` altogether.

**Loading a skill is equivalent to deploying code**, and is gated accordingly.
For hand-written skills and for generated code that leaves the contained set,
that gate is a TOTP code: it is refused when 2FA is not configured, and the file
waits in `<skills_dir>/pending/` until a code is verified, so it cannot replace a
running skill's file beforehand. For generated code that stays contained, the
gate is `CallPolicy` — re-applied on every boot. Only load skills from sources
you trust.

---

## Content Sanitization (Prompt Injection Defense)

External-facing skills (`web_fetch`, `web_search_fetch`, `rss_fetch`,
`web_search`, `web_browse`, `api_request`, `rss_collector`,
`github_security_review`, `google_calendar`, `google_tasks`, `web_automation`,
`research`) fetch data from untrusted sources. Dynamic scraper skills
(`hexdocs_scraper`, `hexdocs_guides_scraper`) also declare `external: true`. This data flows through the
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

**Pre-LLM sanitization:** Fetch skills (`web_fetch`, `web_search_fetch`,
`rss_fetch`, `web_browse`, `web_search`) sanitize fetched content before
building the LLM prompt. Injection payloads are stripped before the model
ever sees them.

**Post-LLM sanitization:** The workflow executor auto-sanitizes output from
any skill tagged `external?/1 == true`, catching skill name leaks or
residual injection artifacts in the LLM response. In composable pipelines
(e.g. `web_fetch → llm_transform`), sanitization runs at the executor level
between steps — the fetch skill's output is sanitized before `llm_transform`
receives it.

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

**An elevation is bounded by time, not by action.**
Within its fifteen minutes, an elevated session may make any control-plane
change the pages expose, not only the one the code was requested for. The
per-action exceptions are the two named above: a database restore, and running
a workflow marked `requires_2fa`.

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
