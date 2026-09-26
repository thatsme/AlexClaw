# Security Policy

## Reporting a Vulnerability

Please do NOT open a public GitHub issue for security vulnerabilities.

Contact: development@securtel.net
Expected response: within 72 hours
Coordinated disclosure: 90 days before public disclosure requested

---

## Published Advisories

| Advisory | Severity | Affected | Fixed |
|---|---|---|---|
| [GHSA-c3fr-cqf2-r6pc](https://github.com/thatsme/AlexClaw/security/advisories/GHSA-c3fr-cqf2-r6pc) — MCP bearer token grants shell command execution without 2FA | High (7.2) | `< 0.3.22` | `0.3.26` |

The fix began in 0.3.22 and is complete from 0.3.26: a database seeded before
0.3.26 kept the original shell allowlist, because a configured row takes
precedence over the compiled default.

The recommended minimum is **0.4.0**, which fixes the findings of a security
review of the 0.3.x code. The advisory's own mitigations rely on two-factor
authentication, and in 0.3.28 and earlier a restart erased the 2FA secret.

---

## Authentication

AlexClaw includes built-in session-based authentication. The web interface
is fully protected — all routes except `/login` require an authenticated session.
There is no anonymous access to any admin functionality.

The first password comes from the `ADMIN_PASSWORD` environment variable (see
`.env.example`). Until someone has logged in, it must be set: without it the
login page shows an error and no access is granted. The first successful login
stores the password's salted hash (PBKDF2-HMAC-SHA256, 600,000 iterations);
from then on the variable is ignored, and changing or removing it changes
nothing. The hash is kept in the database, not in OpenBao, so login works while
OpenBao is unavailable. A stored hash that cannot be read refuses every login:
it never falls back to the variable. The hash and the second factor's settings
are written only by login and second-factor setup, never as settings, from any
entry point.

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
changed and who changed it. A refusal records which of the two it was:
`not_elevated` for a session that has not unlocked, `no_second_factor` for an
instance where nothing can.

### What elevation does not cover

**Database restore is challenged every time**, and refused outright where no
code can be asked for. It replaces the application's data, so it asks for a
code per restore and is never covered by an existing elevation: authority
earned for editing a setting is not authority to replace the data. The upload
is staged on disk while the code is outstanding, and discarded whether the
restore runs or not.

**A restore loads data; it runs nothing.** The file is an export from the
Database page — JSON values, one entry per table. It is parsed and checked in
the application, and the values are inserted through parameterised queries,
each cast to its column's type. Table names, column names and types come from
the live database, never from the file, and a file that disagrees with the
schema in any way is refused before anything changes. The audit log and the
current sign-ins are never touched, and neither is what protects the
installation: the admin's identity (the password's hash, the second factor,
the recovery codes), the login protection (`auth.rate_limit.*`,
`auth.trust_proxy_headers`), the gateway owners, the secrets catalogue — where
each secret may be sent — and the authorisation policies are kept from the
running installation, whatever the file holds, and the result says so. An
export does not carry them. A step or resource in the file may reference only
a secret the installation holds. Once a restore is done, every other admin
session is signed out and cached settings and policies are read again. A full
restore — schema and audit log included — is an operator step with the
database owner's credentials (see [Database Backups](#database-backups)).

Restore only files you created yourself: a restore file is trusted input.

**Running a workflow follows the workflow's own rule.** A workflow marked
`requires_2fa` is challenged when it is run, from the Workflows page and the
Scheduler page alike, and so is a workflow with a `shell`, `coder`,
`db_backup` or `web_automation` step. Editing a workflow is a control-plane
change and needs an elevation; running it is governed by its flag and its
steps.

**Scheduled runs are not challenged.** A schedule is authorised when it is
saved, under elevation. The run that follows is the schedule doing what it was
told to do. A workflow marked `requires_2fa` cannot be scheduled: nobody is
there to approve its runs.

### auth.totp.* is never a setting

The `auth.totp.*` settings are not editable from the Config page at any
elevation, and deleting them is refused for the same reason as changing them.
They are written only by two-factor setup on the Services page, which is also
the only place 2FA is turned off (with a current authenticator code or a
recovery code).

This is load-bearing rather than tidy. Whether elevation is enforced at all is
decided by `auth.totp.enabled`; if that setting were editable from behind the
gate it protects, a session could switch the gate off and then change anything.

### Giving a code

A code is typed into the admin UI, on the page that asked for it. The one
exception is running a workflow marked `requires_2fa`: its prompt is also sent
to the configured gateways, and a code answered there approves that run and
nothing else — whichever answer arrives first performs it and withdraws the
other. A workflow with a `shell`, `coder`, `db_backup` or `web_automation` step
is never offered to a chat. The authenticator app is the second factor either
way, so an instance with no bot configured is fully usable.

Both routes check the code the same way, apply the same replay guard and
limits, and write the same audit row, which records the route.

**Wrong codes are bounded twice.** Three wrong codes lock that session's code
entry for five minutes. Ten wrong codes inside fifteen minutes, counted across
every session, lock web code entry entirely for fifteen minutes, with an audit
row and one notification to any reachable gateway. The second limit is the one
that bounds guessing: a session identifier is a cookie the caller sends, so a
per-session count alone is defeated by discarding it. Both counters live in a
supervised process, not in page state.

**The trade-off, plainly.** Apart from a protected workflow run answered in a
chat, the code is typed in the browser, on the same device as the password.
That is how most two-factor deployments work, and it is weaker than keeping
the two apart.

---

### Recovery codes

Ten one-time codes are generated when 2FA is enabled and shown **once**, in the
browser. They are never sent over a gateway.

What is stored is an HMAC of each code's SHA-256 digest, under an OpenBao
transit key that never leaves OpenBao; OpenBao checks a presented code against
it in constant time. A database dump is not a set of keys and cannot be tried
offline. Codes stored by 0.3.x are re-keyed at the first start of 0.4.0, from
the digest already held: no code has to be generated or saved again.

A recovery code is accepted in the admin UI wherever a code is asked for, and
refused over a gateway: a chat transcript is a durable copy of whatever is
typed into it. It is consumed on use and subject to the same limits as any
other code. Each use writes an audit row, notifies any reachable gateway, and
is shown on the Services page with how many remain. Two or fewer remaining
warns until a new set is generated. Generating a set invalidates every earlier
code and needs a current code itself.

---

### If everything is lost

If both the authenticator and every recovery code are gone, there is no way in
through the application: no page, chat, MCP client or skill can turn the
second factor off without it. The way back in is on the host.

1. On the host, in the deployment's directory, run `make reset-2fa` and type
   `RESET` when asked.
2. It runs inside the running node and turns the second factor off: the
   admin's TOTP key is deleted from OpenBao, every recovery code is removed, an
   audit row is written (caller `operator`, action `reset_second_factor`), and
   a warning says what was done.
3. Sign in with the admin password, set up the second factor again on the
   Services page, and store the new recovery codes.

Only someone with a shell on the host can do this — someone who can already
read the database and OpenBao's volumes. That is why the host, the database,
OpenBao's volumes, its unseal key and its recovery key deserve the care the
rest of this document describes. An Export Data restore does not help here: it
keeps the installation's second factor and recovery codes whatever the file
holds.

---

### Before a second factor exists

With no TOTP configured, nothing can elevate — so the control plane is
**read-only**. Every configuration change, policy edit, provider or resource
change, cluster change, workflow edit and database restore is refused, recorded
in the audit log as `no_second_factor`, and answered with what to do about it.
There is no state in which a control-plane write proceeds on the admin password
alone, and no environment variable that disables the gate.

Setting 2FA up is the one thing the admin password alone can do, because adding
protection is not a privileged act and because requiring a second factor to
configure the second factor would be a locked door with the key inside. It is
configured under **Services → Two-factor authentication**, and only there: the
gateway's `/setup 2fa` is refused, so the secret never travels over a chat.
Setting it up needs OpenBao, which creates and keeps the key. While 2FA is on,
setting it up again is refused: the active factor is replaced only by turning
it off first, which takes a current code.

---

## Two-Factor Authentication

TOTP-based 2FA protects all sensitive operations. Set up in the admin UI
(Services → Two-factor authentication) — compatible with any TOTP
authenticator (Google Authenticator, Authy, etc.).

The TOTP key is created and kept by OpenBao, which also checks every code.
While OpenBao is unavailable, codes cannot be checked — neither authenticator
codes nor recovery codes — so nothing can be unlocked or approved until it is
back; the answer is "unavailable", which is not counted as a wrong code. The
admin password still signs in.

**Operations requiring a code of their own (never covered by an elevation):**
- **Skill load and reload** — a code typed on the Skills page
- **Database restore** — a code per restore
- **Turning 2FA off, and generating a new set of recovery codes**
- **Running a workflow marked `requires_2fa`, or one with a `shell`, `coder`,
  `db_backup` or `web_automation` step**, from the admin UI

Every other control-plane change, skill unload included, needs an elevation
(above).

**Attempt limit.** A challenge lives for two minutes and accepts any six digits
in that time. Without a bound those two minutes are a guessing window, and the
gateway will deliver as many messages as it is sent. The challenge carries its
attempt count: the third wrong code deletes it, and the action must be
triggered again, which mints a fresh challenge.

**Replay protection.** OpenBao's TOTP engine refuses a code it has already
accepted, but that memory is lost when OpenBao restarts, so AlexClaw keeps its
own guard as well: the last accepted code is refused for 90 seconds, as long as
it could be valid. It keeps a keyed fingerprint of that code
(`auth.totp.last_used_at`), never the code, in a settings row, so the guard
survives a restart of AlexClaw.

**Where the key is.** AlexClaw never stores the TOTP key. Enrolment has OpenBao
create it and shows it once; OpenBao's policy lets AlexClaw check a code but
never generate one. An enrolment made by 0.3.x is imported into OpenBao the
first time it is needed (or at the first start of 0.4.0) and its row is
deleted; the authenticator app keeps its entry.

**Privileged skills do not run from a chat, or from another skill.** The four
privileged core skills — `shell`, `coder`, `db_backup`, `web_automation` — run
only as a workflow step, in a run the scheduler starts or one the admin UI
starts with a code. `SkillAPI.run_skill/3` refuses them outright: there is no
interactive user to prompt on a workflow step or a reasoning-loop iteration.

**Skill management starts only from the Admin UI.** Load (by upload) and
reload each need a code typed on the Skills page; unload needs an elevation.
All three are refused when 2FA is not configured. The `/skill` commands on
Telegram/Discord only answer that skill management is available from the
Admin UI. The `/skills` command still lists registered skills, and skills
execute normally within workflows.

---

## Telegram Gateway Security

AlexClaw only responds to messages from the owner: the user
`telegram.owner_user_id`, in the chat `telegram.chat_id`, both set in the
admin UI. In a group only that user's messages count; messages from any other
chat or user are ignored, and with no owner user set nothing is answered.
Discord works the same way (`discord.owner_user_id` in `discord.channel_id`).
A stolen bot token lets someone read what is sent to the bot and post as it;
with the owner user id set, it does not let them command AlexClaw.

---

## GitHub Webhook Verification

The `/webhooks/github` endpoint verifies all incoming payloads using
HMAC-SHA256 with `Plug.Crypto.secure_compare` for timing-safe comparison.
Webhooks without a valid signature are rejected with 401.
If no webhook secret is configured, all webhooks are rejected.
Set `github.webhook_secret` in Admin > Config (GitHub category).

---

## MCP Server Authentication

The MCP endpoint (`/mcp`) lets external clients read AlexClaw's data and run
its workflows over the Model Context Protocol. The tools are the enabled
workflows that do not require 2FA; there are no skill tools. A run is performed
through the control plane, which refuses a workflow that is disabled, marked
`requires_2fa`, or has a `shell`, `coder`, `db_backup` or `web_automation`
step.

**Bearer token auth:** Every MCP request must include `Authorization: Bearer <token>`. AlexClaw never stores the MCP key: it keeps only a fingerprint, an HMAC of the key computed by OpenBao's transit engine with a key AlexClaw never holds (`AlexClaw.MCP.Key`). A request is admitted when the HMAC of the presented token equals the stored fingerprint, compared with `Plug.Crypto.secure_compare/2` (constant time). Requests without a valid token receive 401. A copy of the database holds nothing that can be turned back into the key or tried offline, and no API returns it (`Config.secret/2` answers `{:error, :not_retrievable}`).

**Key management:**
- The key is generated by AlexClaw on the Config page (group **MCP**, "Generate"), behind the admin second factor, and shown once in the reply to that action. It cannot be shown again
- No automatic expiration — treat the MCP key like a long-lived API key
- Generating a new key replaces the old one at once; "Revoke" leaves no key, and MCP then refuses every request
- If compromised: generate a new key, or revoke it
- Upgrading from 0.3.x keeps an existing key working: its fingerprint replaces it at the first start

**Policy enforcement:** MCP tool calls pass through `PolicyEngine.evaluate/2` with `:mcp` caller type before the run is started. The `mcp_restriction` policy rule type blocks tools by name — a policy with `rule_type: "mcp_restriction"` and `config: {"tool_pattern": "workflow:Nightly Report", "match": "exact", "action": "deny"}` blocks that workflow. Without `"match": "exact"` the pattern matches any tool name that contains it. Policies are saved on the Policies page, under elevation.

**Resource filtering:** Sensitive config values (API keys, OAuth tokens) are redacted in MCP resource responses — only `[REDACTED]` is returned for settings marked `sensitive: true`.

**Audit logging:** Every MCP run, allowed or refused, is recorded in `auth_audit_log` by the control plane with caller `mcp:<client name>`; a policy denial is recorded with the tool's name (`mcp:workflow:<name>`). Both are visible in Admin > Policies > Audit Log.

**Advisory:** before 0.3.22 the bearer token alone reached the `shell` and
`coder` skills with no second factor. See
[GHSA-c3fr-cqf2-r6pc](https://github.com/thatsme/AlexClaw/security/advisories/GHSA-c3fr-cqf2-r6pc).
The `mcp_restriction` policy type was part of that fix; since 0.4.0 MCP
exposes no skill at all.

**Hardening recommendations:**
- The `/mcp` endpoint must be behind TLS — never transmit Bearer tokens over plain HTTP
- Store the MCP API key in your client's config securely (environment variable or encrypted config)
- Monitor the Audit Log for unexpected MCP activity
- Use `mcp_restriction` policies to limit which workflows MCP clients can run
- If MCP is not needed, do not generate a key — the auth plug rejects all requests while none is configured

---

## Inter-Node Authentication (Clustering)

Multi-node clusters authenticate via BEAM's distributed Erlang protocol:

- All nodes must share the same `CLUSTER_COOKIE` (set via environment variable)
- EPMD (Erlang Port Mapper Daemon) on port 4369 coordinates node discovery
- Nodes without the correct cookie cannot join the cluster or trigger remote workflows
- A node is registered in the admin UI (Cluster page, with the elevation); connecting with the cookie does not register it, and an unregistered node's arrival is audited
- A request from another node names no one: the receiving node takes the sender from the connection. It runs only an enabled workflow that does not require 2FA and has no `shell`, `coder`, `db_backup` or `web_automation` step, whose step 1 is the `receive_from_workflow` gate and whose `allowed_nodes` names that registered node — an empty `allowed_nodes` allows no one. A refusal is audited, and nothing starts

**Hardening recommendations:**
- Generate `CLUSTER_COOKIE` with `openssl rand -base64 32` — treat it like `SECRET_KEY_BASE`
- EPMD port (4369) and BEAM distribution ports (dynamic, high range) should NOT be exposed to the internet
- Restrict inter-node traffic to private networks, VPCs, or Docker networks
- When running across machines, use VPN or SSH tunnels between Docker hosts

---

## Shell Skill (Container Introspection)

The `shell` skill runs OS commands inside the container for diagnostics
(disk, memory, connectivity, BEAM status), as a workflow step only. It is
protected by 5 layers of defense-in-depth:

1. **Disabled by default** — `shell.enabled` must be explicitly set to `true` in Admin > Config. The skill checks it on every run.
2. **Second factor** — a run with a `shell` step starts only from the scheduler, or from the admin UI with a code. It is refused from a chat, MCP, a webhook and another node, before any step runs.
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
and bare `ps`. From 0.3.26 the seeder seeds `Shell.default_whitelist/0` itself
rather than a second copy, and a test fails the build if a literal returns.

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
- **Command from step config** — the command comes from the step's configuration, never from chat or other user input, preventing injection through workflow chaining

**The code is the boundary.** A workflow with a `shell` step is refused
outright from every entry point that is not the admin UI or the scheduler, and
the admin UI asks for a code to run it. A schedule is authorised when it is
saved, under elevation.

---

## Web Automator Sidecar

The web-automator sidecar runs a real browser with network access. A recipe
is limited to a fixed set of browser actions — no script evaluation — but it
still acts on live pages with whatever the page allows, so recorded recipes are
reviewed before they are assigned to scheduled workflows.

- **Authentication.** Every sidecar route except `/health` requires
  `Authorization: Bearer <token>`, compared in constant time. The token is
  generated at the first start, by a one-shot service with no network, into a
  volume that otherwise only AlexClaw and the sidecar mount, read-only; no
  operator sets or copies it. With no token the sidecar
  refuses every protected route, and AlexClaw sends it nothing. The interactive API documentation is not served.
- **Network.** The sidecar is on its own `automation` network, shared with the
  AlexClaw container and not with the database. Its API port (6900) is not
  published on the host. On some Docker engines traffic by IP address still
  passes between networks (arriving from the database network's gateway), so
  the database does not rely on the network: its `pg_hba.conf` accepts network
  connections only from the pinned addresses of AlexClaw and the migrate job,
  and refuses everything else before a password is asked for. The sidecar
  holds no database credentials.
- **Process.** The sidecar runs as an unprivileged user with every capability
  dropped, no privilege escalation, and a read-only root filesystem; only a
  tmpfs `/tmp` is writable.
- **Egress during a replay.** The replay browser reaches the network only
  through a filtering proxy that applies the same rule as skill HTTP (below):
  a destination that does not resolve, or resolves to any internal address, is
  refused, and the connection goes to the address that was checked. QUIC,
  non-proxied WebRTC UDP and service workers are disabled.
- **Recording sessions.** A recording session's browser is not
  egress-filtered: it is driven by hand, through noVNC.
- **noVNC.** The recording display (port 6080) has no password: anyone who
  reaches it controls the recording browser. It is published on `127.0.0.1`
  only and is meant to be reached through an SSH tunnel.
- **Recipe contract.** The sidecar validates a whole recipe before running any
  step: a known action, only that action's fields, http(s) URLs, and bounded
  waits and timeouts. Anything else refuses the recipe. There is no action
  that runs JavaScript and no caller-chosen output path.
- **Bounded plays.** Every play has a deadline (at most ten minutes) and its
  own browser, closed when it ends. One play runs at a time. A play whose
  caller disconnects is cancelled; one whose caller gives up waiting is
  stopped by its id, so a stop cannot end a different play.
- **Logs.** The player and the recorder write selectors and action names to the
  sidecar's log, never the values typed into a page, and a recording that fails
  to save is reported without its steps.
- **Recordings.** A credential field, `type="password"` or an `autocomplete`
  of `current-password`, `new-password` or `one-time-code`, is recorded as a
  login slot, without its value. The page's listener leaves the value out, and
  the recorder drops it if one arrives.
  - A recording with an empty slot cannot be played. The Resources page names
    the fields that need a login and takes one for each, behind the admin
    second factor.
  - Every fill value a recording keeps is stored in OpenBao, bound to the
    recording's origin (see [Secrets in OpenBao](#secrets-in-openbao)).

---

## Database Backups

The `db_backup` core skill produces gzip-compressed `pg_dump` files on a
host-mounted directory. A backup holds the **full database contents**:
workflows, memories, knowledge, settings, the audit log, and references to
secrets — not the secrets, which are in OpenBao. It also holds what protects
the installation in a form safe at rest: the admin password's hash, the
recovery codes' HMACs and the MCP key's fingerprint.

**A database backup alone does not restore credentials.** The references
resolve only against the OpenBao that holds them, so OpenBao is backed up
together with the database. `make backup-openbao` writes a snapshot of
OpenBao's data to `OPENBAO_BACKUP_DIR`, readable by its owner only, and checks
the snapshot's own checksums before it reports success. The snapshot is taken
by a one-shot service with a credential that may read a snapshot and nothing
else; AlexClaw never holds that credential. It is written where AlexClaw does
not mount: the command refuses an `OPENBAO_BACKUP_DIR` that is `BACKUP_DIR`,
the `db_backup` skill's directory, or inside it. A snapshot is sealed with OpenBao's unseal
key and holds neither that key nor the recovery key; without the same unseal
key file it cannot be opened. Procedure:
[Backing up and restoring OpenBao](docs/architecture/openbao.md#backing-up-and-restoring-openbao).

Backups made by 0.3.x hold that version's credentials, encrypted under
`SECRET_KEY_BASE` or in plaintext: after upgrading, rotate every third-party
credential AlexClaw held, and archive or delete those backups.

**Security considerations:**
- Backup files should be stored on an encrypted filesystem or encrypted at
  the host level — they hold plaintext data (workflows, memories, knowledge
  entries, settings)
- Restrict host directory permissions (`chmod 700`) to prevent unauthorized access
- The skill verifies the backup directory is a real bind mount, not the
  container overlay FS — this prevents backups from being silently lost on
  container recreation
- Backup rotation (configurable `backup.max_files`) limits exposure window —
  old backups are deleted automatically
- A backup is made as the application role, which may read every table, so
  it holds the audit log too
- To restore a backup — an operator step, with the database owner's
  credentials, that replaces the whole database: recreate the database, load
  the backup with `psql --single-transaction -v ON_ERROR_STOP=1`, then run
  `docker compose run --rm migrate` to bring the schema up to date and grant
  the application role its privileges. The exact commands are in
  [Upgrading to 0.3.34](docs/deployment/upgrade-0.3.34.md#restoring-after-0334).
  A full restore replaces everything in the database, the admin's password
  hash, second-factor markers and recovery codes included, and restores
  nothing in OpenBao: the references in the backup resolve only against the
  OpenBao data they were made with

---

## Database Roles

AlexClaw connects to PostgreSQL as its own **application role**, not as the
database owner.

- The application role owns no table and cannot create roles or databases.
  AlexClaw refuses to start in production on a connection that is a superuser,
  can create roles or databases, bypasses row-level security, or owns a table
- On the audit log it may **read and insert only**. Update, delete, truncate,
  alter and drop are refused by the database. Rows older than thirty days are
  pruned by `prune_auth_audit_log()`, a function owned by the owner. Its floor
  is fixed in the database, not chosen by the application
- Every table's privileges are an explicit decision. A table added without
  one fails the migration step, and the build
- Migrations run in a one-shot `migrate` service with the owner's credentials,
  which no other application container receives. That service is never given
  `SECRET_KEY_BASE`, which signs sessions and, at the first start of 0.4.0,
  reads what 0.3.x encrypted: the owner's credentials and that key never share
  a container, and a test fails the build if a compose file puts them together
- Upgrading an existing installation: [Upgrading to 0.3.34](docs/deployment/upgrade-0.3.34.md)

---

## Secrets in OpenBao

Credentials are kept in OpenBao, not in the database. A record that needs one
holds a reference to it, and every use is resolved for a destination and
audited.

OpenBao runs in its own container, on an internal network shared only with
AlexClaw and OpenBao's own init and backup services, with nothing published to
the host. AlexClaw reaches it over TLS 1.3, verified against a CA whose key is
discarded at creation, and logs in with an AppRole bound to AlexClaw's fixed
address; its token lives in one process's memory. The policy allows only
AlexClaw's own paths, HMAC and HMAC verification with one transit key, and
creating, checking — never generating a code from — and deleting the admin's
TOTP key. A separate `backup` AppRole may read a snapshot and nothing else:
its token is single-use, lasts five minutes and is bound to the backup
service's address, and its credentials are on a volume AlexClaw does not
mount. OpenBao keeps its own audit log, out of AlexClaw's reach, and AlexClaw
is given no access unless that log is on. The root token is revoked once
OpenBao is initialised, and none is kept: making one needs the recovery key.
OpenBao unseals itself from a key file on the host, mounted into its container
only. Details: [OpenBao](docs/architecture/openbao.md).

**Secret settings:** `telegram.bot_token`, `github.token`,
`github.webhook_secret`, `llm.gemini_api_key`, `llm.anthropic_api_key`,
`google.oauth.client_secret`, `google.oauth.refresh_token` and
`discord.bot_token`.
- Each is bound to the hosts it is sent to, derived from the configuration
  every time it is resolved.
- `Config.get/2` refuses them; `Config.secret/2` resolves one for a bound
  destination only.
- The Config page shows when each was set, never the value.

The MCP key is not stored at all: see
[MCP Server Authentication](#mcp-server-authentication).

**Credentials in steps and resources:** a Telegram Notify step's own
`bot_token`; every header of an API Request step; a resource's
`metadata["auth"]["value"]`; and every fill value of a recording, or of a Web
Automation step's inline recipe, including logins attached to a recording.
- Fill values are bound to the recipe's **origin** (`scheme://host[:port]`),
  and a play resolves them for that origin only. Each login fill carries that
  origin to the web automator, which types it only while the page is on it: a
  page that navigated or was redirected elsewhere fails the play, and nothing
  is typed.
- Every header value is a secret, whatever the header's name: a name says
  nothing reliable about the value, so none is guessed. An LLM provider's
  headers are kept the same way.
- Each is a secret the step or resource owns, and its row keeps a reference.
- It is bound to the host it is sent to **when it is entered**: the step's URL,
  the Telegram API, the resource's API base (else its URL) — also for an API
  Request step addressed through its workflow's API resource (`{base_url}`
  or a `path`) — or, for fill values, the recipe's origin. A credential with
  no such host is refused.
- Moving a step or resource to another host while keeping the credential is
  refused. The credential has to be entered again for the new host.
- A skill never holds the value. The step and its resources reach it with a
  placeholder, `{{secret:NAME}}`. The HTTP layer attaches a value only in a
  declared slot: a step's configured headers and its resource's auth header
  (API Request), a step's own bot token (Telegram Notify), a header a skill
  names in `:secret_headers` (`SkillAPI.http_request`), an LLM provider's key
  and headers. No text is searched for placeholders: one in a URL, a body, a
  message or a step's input is sent as written.
- A slot is filled only for a secret the step was given, resolved for the
  host the request actually goes to. A step is given its own secrets; a
  resource's credential only to the skills that attach it in a slot (API
  Request, Web Automation). A process running no step is given none. A
  request whose URL, input or redirect would take the credential to another
  host is refused, as is a slot naming a secret the step was not given.
- A request that carries a credential is not followed across a redirect to
  another host; the redirect is refused.
- Run records, exports and MCP show a placeholder.
- Deleting a step, workflow or resource deletes its secrets. Duplicating a
  workflow copies them.

**A URL carrying `user:password`** is refused, on a resource and on an API
Request step's `url`. Such a URL would be stored, shown and logged with the
password in it.

**Upgrading from 0.3.x** carries every existing credential over unchanged, at
the first start, before the gateways:
- each value is stored in OpenBao, read back and compared, and only then
  removed from its row;
- a value that cannot be moved stays where it was and is tried again at the
  next start;
- a value already in OpenBao is never overwritten: when the secret a 0.3.x
  value would move to holds another value, entered after a first start that
  could not reach OpenBao, that value is kept, the 0.3.x row is left as it
  was, and the conflict is logged by name. An LLM provider whose credentials
  were entered again in 0.4.0 keeps them the same way.

## Encryption at Rest

Since 0.4.0 no credential is kept in AlexClaw's database, encrypted or not:
settings, workflow steps, resources and LLM providers hold references to
secrets in OpenBao (see [Secrets in OpenBao](#secrets-in-openbao)), which
encrypts them. Nothing is encrypted at the application level with a key
derived from `SECRET_KEY_BASE`.

- A setting named like a credential (`api_key`, `token`, `password` or
  `secret` in its key) is refused unless it is a declared secret setting,
  which is routed to OpenBao.
- The rows AlexClaw keeps that relate to credentials are designed to be safe
  at rest: the MCP key's fingerprint and the recovery codes' HMACs (both under
  a key that never leaves OpenBao), the admin password's salted
  PBKDF2-HMAC-SHA256 hash, and the TOTP replay guard's keyed fingerprint of
  the last accepted code.
- Every cached row carries its `sensitive` flag alongside its value, and
  `SkillAPI.config_get/3` refuses any key marked sensitive. A key the cache
  does not know is treated as sensitive.
- An LLM provider's API key and header values are secrets bound to the host
  its calls go to; the row keeps the header names and references.

**Upgrading from 0.3.x.** 0.3.x encrypted sensitive settings and some
credentials under `SECRET_KEY_BASE`. The first start of 0.4.0 reads them, once
and under the same `SECRET_KEY_BASE`, and leaves nothing encrypted: each
credential is moved into OpenBao (read back and compared before its row is
changed); the MCP key's fingerprint and the admin password's hash go back to
their plain form; a setting the admin had added and marked sensitive is moved
into OpenBao as a parked secret, sent nowhere, and named in the log to be
declared or deleted. Parked secrets have their own names (`parked_…`, one per
setting), so a parked setting never replaces a declared secret or another
parked one. `SECRET_KEY_BASE` must not change until that first start
has run. A value that cannot be moved stays in its row, is never used — a step
or resource holding one refuses to run — and is tried again at the next start.

**Changing `SECRET_KEY_BASE`** ends every login; no stored value becomes
unreadable. See [Rotating SECRET_KEY_BASE](docs/deployment/rotate-secret-key-base.md).

A skill whose configuration has a key with a name
one of whose underscore-separated parts is `token`, `key`, `apikey`,
`password`, `secret`, `credential`, `auth`, `authorization` or `headers` must declare it with
`secret_config_keys/0`: a core skill that does not fails the build, and a
dynamic skill that does not is refused at load. Seeded cloud providers read
their key from its setting rather than holding a copy.

**Export Data** carries no credential: the file holds references, never a
value, and not the secrets catalogue, which a restore keeps. A restore refuses a
file holding values 0.3.x encrypted: such a file is restored into 0.3.x and
upgraded.

---

## Dynamic Skill Loading

Dynamic skills are compiled into the BEAM VM at runtime. The source is parsed
and vetted as a syntax tree **before** anything is compiled, because compiling a
module runs its body. The following protections are in place:

- **2FA on every manual load** — load and reload each need a TOTP code typed on the Skills page, and are refused when 2FA is not configured; unload needs an elevation. Every dynamic skill, uploaded or generated, must also be contained (below); a code approves the permissions a skill declares, never calls outside the contained set
- **Started only from the Admin UI** — load (by upload), unload and reload are Admin UI actions, and staging an upload needs an elevation. The `/skill` commands on Telegram/Discord only answer that skill management is available from the Admin UI; `/skills` still lists the registered skills. Code cannot be uploaded from a messaging app, and an uploaded file waits outside the live skills directory until its code is verified
- **Version bump enforcement** — loading a skill that's already loaded with the same version is rejected. The developer must bump `version/0` or use reload to force
- **Path restriction** — only files inside the configured `SKILLS_DIR` volume are accepted
- **One module per file** — the file's top level must be exactly one `defmodule` and nothing else. Without this rule, a file carrying a second module could replace a core module such as `AlexClaw.Auth.PolicyEngine` in the running VM, and a statement outside the module would run at compile time
- **Namespace enforcement** — module must be `AlexClaw.Skills.Dynamic.*`, checked on the syntax tree before compiling
- **No compile-time execution** — the module body is limited to `def`, `defp`, `@`, `alias` and `require`. Attributes must be literals or `~w`/`~s`/`~r` sigils; `@on_load`, `@after_compile`, `@before_compile`, `@on_definition`, `@compile`, `use`, and `unquote` are rejected
- **No imports** — a dynamic skill cannot import anything (Kernel's defaults aside). After an import, a module's functions are local calls, which the containment check does not see; without one, every call to another module is written in full and checked. `require` is limited to `Logger`, whose level functions are macros: a require brings no function into scope. Both rules hold anywhere in the file, since a macro expands at compile time wherever it is called, including inside a function body
- **Behaviour validation** — module must export `run/1`
- **Permission sandbox** — skills declare permissions; `SkillAPI` enforces them at runtime. Undeclared permissions return `{:error, :permission_denied}`. No permission lets a skill write or load a skill, or create, change or start a workflow
- **Privileged skills are unreachable from another skill** — `SkillAPI.run_skill/3` refuses `shell`, `coder`, `db_backup` and `web_automation` for every caller, dynamic or core, and logs the attempt as a denial. Those four run only as workflow steps in a run the scheduler starts or the admin UI starts with a code, so the skill-to-skill route is closed rather than gated
- **Privileged steps run only in a run the scheduler starts, or one the admin UI starts with a code** — a run of a workflow with a `shell`, `coder`, `db_backup` or `web_automation` step, started from MCP, a webhook, a chat (even with a code) or another node, is refused before it starts, naming the step: no step of it runs. A privileged skill counts whether it is a step's own skill or the fallback the step runs when its circuit is open. The control plane decides from the entry point; a caller cannot claim it. The admin UI asks for a code to run a workflow that has such a step, and does not offer the chat that approval
- **Secrets do not reach skills** — `SkillAPI.config_get/3` returns `{:error, :sensitive}` for any setting marked sensitive, and for any key the config cache does not know. `SkillAPI.list_resources/2` and `get_resource/2` drop `metadata["auth"]` and strip userinfo from the resource URL
- **Integrity checksums** — SHA256 of source file stored on load, verified on boot. Mismatched files are skipped
- **Core protection** — core skills cannot be unloaded or overwritten by dynamic skills
- **No NIF compilation** — the Alpine runtime image has no build tools, preventing native code loading
- **External skill detection (AST-based)** — at load time, dynamic skill source is AST-scanned for calls to HTTP/socket libraries (Req, HTTPoison, Finch, Tesla, `:gen_tcp`, `:httpc`, SkillAPI.http_*). If detected without `def external, do: true`, the skill is **rejected** (fail-closed). This prevents untagged dynamic skills from fetching external data without proper sanitization. The scan covers the skill's own file only

**Circuit breaker protection:** Each skill (core and dynamic) is wrapped by an
OTP circuit breaker. After 3 consecutive failures, the circuit opens and calls
are rejected instantly without executing the skill. This prevents a failing
dynamic skill from consuming resources or cascading failures through workflows.
Workflow steps can be configured to skip or fallback to an alternative skill
when a circuit is open or a skill is missing.

**Skill generation (the Forge page):**

The Forge admin page generates a skill with a model, from a goal typed on the
page, with the page unlocked (an elevation). Its engine is the `coder` core
skill, which is reached only from that page: it is not a chat command, an MCP
tool or a workflow step. What happens next depends on what the generated code
calls.

**Contained code loads without a 2FA code.** After generation the source is
staged in `<skills_dir>/pending/`, compiled far enough to be read, and checked by
`AlexClaw.Skills.CallPolicy`. A skill is *contained* when every remote call it
makes resolves to one of:

> `SkillAPI`, `Skills.Helpers`, `Enum`, `Map`, `MapSet`, `List`, `Keyword`,
> `Tuple`, `Stream`, `Range`, `Access`, `String`, `Integer`, `Float`, `Regex`,
> `Jason`, `Base`, `URI`, `Date`, `Time`, `DateTime`, `NaiveDateTime`,
> `Logger`, `Floki`, `:math`

plus calls to itself. `Logger` is limited to its level functions, since it
also carries configuration and backend control (a skill cannot import it, so
every call to it is written in full and checked). `Path` is
limited to the functions that take names apart and put them together (`join`,
`basename`, `dirname`, `extname`, `rootname`, `split`, `relative`,
`relative_to`, `type`): the rest of it lists the filesystem (`wildcard`) or
reads the working and home directories (`expand`, `absname`,
`relative_to_cwd`). Five single functions of otherwise refused modules are
allowed: `System.monotonic_time`, `Process.sleep`, `Exception.message`,
`:crypto.hash` and `Kernel.to_string` (what string interpolation compiles to).
Typespecs are allowed. Refused: dynamic dispatch (a module in a variable,
`apply/2`, `apply/3`), `spawn`, `send`, atom creation from runtime data
(`String.to_atom/1`, `List.to_atom/1`, `Jason.decode` with any `keys:` other
than `:strings`), and any alias form that cannot be resolved statically
(`alias ..., as:`, `A.{B, C}`). `SweetXml` is deliberately absent: its parse
options decide entity handling. A skill reads XML
with `SkillAPI.parse_xml/2`, which refuses any document type or entity
declaration and returns plain maps.

**The permissions it declares are capped too.** Containment bounds which modules
the code may call; it cannot bound what `SkillAPI` does on the skill's behalf,
and the permissions were written by the same model that wrote the code. An
unattended load may hold only `:llm`, `:web_read`, `:memory_read`,
`:knowledge_read`, `:resources_read` and `:gateway_send`.

Two exclusions are worth spelling out, and each is defended twice.
`:skill_invoke` reaches core skills: `SkillAPI.run_skill/3` resolves through the
registry, which resolves core skills — a route to `shell`, `coder`, `db_backup`
and `web_automation`, none of which checks 2FA inside `run/1`. `run_skill/3`
refuses those four by name for any caller and records the attempt as a denial,
so the ceiling is not the only thing standing between a generated skill and a
shell. `:config_read` returned plaintext API keys from the settings cache in
0.3.x. Since 0.4.0 credentials are not settings values at all — they are in
OpenBao and never enter the cache — and `config_get/3` also refuses any key
marked sensitive, and any key the cache does not know.

The ceiling keeps both exclusions regardless. A permission that is only safe
because of a second check is not a permission an unattended load should hold.

`:web_read` together with any of the private reads is refused as a pair even
though each is allowed alone — read and then post is an exfiltration path.
`:gateway_send` with a private read stays allowed, because that output goes to
the configured chat rather than anywhere the skill chooses.

`:resources_read` is inside the ceiling. A resource row holds only a reference
to its credential, and a URL carrying `user:password` is refused on save;
`SkillAPI` still drops the `auth` key from resource metadata and strips
userinfo from resource URLs before returning either. A skill can name a
resource and ask for a request against it; the credential is attached only at
send, for the resource's host, and never passes through the skill.

Contained code within the ceiling is promoted out of `pending/` and loaded with
approval `containment`.

**Generation cannot take over a name it does not own.** A generated skill may
replace another generated skill that was approved by containment, and nothing
else. An uploaded skill, a generated skill approved by a TOTP code, and a core
skill name are all refused — otherwise a goal whose derived name happened to
collide would quietly replace a skill somebody had approved.

**Calls outside the envelope are approved by no one.** The violations are fed
back to the model as a retry hint naming the calls to replace. If it still
cannot get inside the envelope, the skill is not loaded. Contained code that
declares more than the unattended ceiling stays in `pending/`, and loads only
with a code that approves those permissions — recorded as approval `totp`.
With 2FA unconfigured it is refused and left staged.

**Containment is checked at every load and on every boot, for every dynamic
skill**, whoever approved it, against the current allowlist. The allowlist can
tighten between releases, and a skill should not keep running on a verdict that
no longer holds; a skill that no longer passes is not loaded.

**What containment is not.** It is static analysis of direct calls in one file.
The allowed modules are still real code: `SkillAPI` genuinely acts on the skill's
behalf — within the permissions the skill declared, which the model also wrote —
and `Logger` genuinely writes to the logs. Containment bounds *what a generated
skill can reach*, not what it can do with what it reaches. A contained skill can
still exfiltrate through `SkillAPI.http_get/3` if it holds `:web_read`, and can
still write nonsense to memory if it holds `:memory_write`. Skill HTTP cannot
reach internal hosts: every request, redirect hop and retry resolves the host,
is refused if any address is loopback, private, shared (`100.64.0.0/10`),
link-local or otherwise internal, and connects to the address it checked; the
options that would replace the transport are refused. Review the
permissions on generated skills, and treat the model producing them as part
of the trust boundary.

The generated code additionally passes the same load-time validation as a
hand-written skill (one module per file, namespace, module body restrictions,
behaviour, permission checks). Other safety measures:
- Filename validation rejects path traversal (`..`, `/`, `\`)
- Only `.ex` files can be written
- Writes are confined to `<skills_dir>/pending/` until the skill is approved
- A generated skill cannot create a workflow; its workflow is created on the Workflows page
- Each loaded skill is recorded with its origin (`generated` or `upload`) and its approval (`containment` or `totp`)
- **Forge's provider selector lists every configured provider**, so generation can be routed to a cloud model. The default is local. Choosing otherwise puts a third party in the loop for code that will be compiled into the running VM, and widens the trust boundary described above beyond the local model
- One generation runs at a time, with at most five attempts and a time budget across them (`forge.time_budget_seconds`, default ten minutes)
- `run/1` is exercised through `SafeExecutor` with a timeout during validation, never called directly, and only for contained code

**What is NOT sandboxed:** containment is static analysis of the direct calls
in one file; the permissions a skill declares decide what `SkillAPI` does on
its behalf. Once loaded, a skill runs in the same BEAM VM as the rest of
AlexClaw. Containment bounds which modules its source names, not what the
allowed modules do with what they are given.

**The permissions a skill declares are an API contract, not a sandbox.**

**Loading a skill is equivalent to deploying code**, and is gated
accordingly: an uploaded skill, and generated code beyond the unattended
ceiling, load only with a TOTP code, and the file waits in
`<skills_dir>/pending/` until then, so it cannot replace a running skill's
file beforehand. Every dynamic skill must be contained. Only load skills from
sources you trust.

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
- Links in an `llm_transform` summary of feed items come from the items, never
  from the model: URLs with a scheme or `www.` are removed from the model's
  reply, but a bare domain quoted from feed text (`example.com`) can remain, and
  Telegram may render it as a link

---

## Agent Authorization Layer

AlexClaw implements a composable authorization layer for skill execution,
inspired by Macaroon-style capability tokens and policy-as-code evaluation.

**Context-aware permission checks:**
Every `SkillAPI` call builds an `AuthContext` (caller, type, permission,
chain depth, workflow run ID, timestamp) and evaluates it through the
`PolicyEngine`. Core skills bypass all checks — core is decided by where the
code runs (`SafeExecutor`), never by what a caller claims. Dynamic
skills are checked against their declared permissions, capability tokens,
and active policy rules.

**Capability tokens (Macaroon-style):**
When a workflow executes, each step receives an HMAC-signed capability
token scoped to the skill's declared permissions. Cross-skill invocation
via `run_skill/3` attenuates the token — a child skill can only receive
a subset of the caller's permissions, never more. Tokens are signed
with a key derived from `SECRET_KEY_BASE` via HKDF-SHA256.

**Chain depth enforcement:**
Skill-invokes-skill chains are limited to depth 3.
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

Policies are stored in PostgreSQL and saved from Admin > Policies, under
elevation; a saved change takes effect at once. The engine keeps them in a
cache that is read again every 30 seconds.

**Audit logging:**
All authorization denials are persisted to the `auth_audit_log` table
with full context (caller, permission, reason, chain depth, workflow run).
Viewable from Admin > Policies > Audit Log. Auto-pruned after 30 days.

**Limitation:** the authorization layer is enforcement at the API boundary.
What keeps a dynamic skill from calling internal modules directly is
containment, a static check of the calls its source names — not a sandbox.
Only load skills from trusted sources.

---

## Known Limitations and Design Decisions

**LLM prompts may contain user data.**
Workflow steps send data to external LLM providers (Anthropic, Google Gemini).
Review which providers are enabled and their data retention policies before
processing sensitive information.

**An elevation is bounded by time, not by action.**
Within its fifteen minutes, an elevated session may make any control-plane
change the pages expose, not only the one the code was requested for. The
per-action exceptions, each asking for a code of its own, are loading or
reloading a skill, a database restore, turning 2FA off, generating recovery
codes, and running a workflow that is marked `requires_2fa` or has a
privileged step.

**Built-in login rate limiting.**
Failed login attempts are tracked per IP using ETS. After 5 failures
(configurable), the IP is blocked for 15 minutes (configurable).
Limits are adjustable at runtime from the Config UI without restart.

---

## Deployment Hardening

- Run behind a reverse proxy with TLS — never expose port 5001 directly
- Set a random `SECRET_KEY_BASE` of at least 64 bytes (`openssl rand -base64 48`); the application refuses a shorter one. It signs sessions; changing it ends every login and makes nothing unreadable ([Rotating SECRET_KEY_BASE](docs/deployment/rotate-secret-key-base.md)). When upgrading from 0.3.x, keep it unchanged until the first start of 0.4.0 has run
- Keep OpenBao's unseal key file and recovery key offline, apart from the host's backups: losing the unseal key loses every secret, and anyone holding both it and OpenBao's data volume holds every credential ([OpenBao](docs/architecture/openbao.md))
- Back up OpenBao (`make backup-openbao`) together with the database, to a directory AlexClaw does not mount ([Database Backups](#database-backups))
- Set `ADMIN_PASSWORD` to a strong random value before the first login; it is ignored afterwards
- Restrict PostgreSQL to localhost or internal network only
- Built-in login rate limiting is active by default (configurable via Config UI)
- Never expose noVNC port (6080) publicly — it provides unauthenticated browser access

---

## Scope

AlexClaw is designed as a single-user personal agent. Multi-user access
control is not in scope. The authentication model assumes a single trusted
operator.
