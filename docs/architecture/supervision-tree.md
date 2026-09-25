# Supervision Tree

AlexClaw uses a flat `one_for_one` supervision strategy. Each child is
independent — a crash in one does not restart the others. The chat gateways are
the one exception to the flat shape: they sit under their own supervisor.

```
AlexClaw.Application (one_for_one)
  ├── AlexClaw.Repo                      # PostgreSQL connection pool (Ecto)
  ├── Phoenix.PubSub (AlexClaw.PubSub)   # Config changes, skill list, run events
  ├── Task.Supervisor (AlexClaw.TaskSupervisor)  # Supervised fire-and-forget work
  ├── AlexClaw.Vault.Supervisor          # The OpenBao client's branch (see below)
  │   └── AlexClaw.Vault                 # Logs in to OpenBao; every secret call
  ├── AlexClaw.Auth.AuditLoss            # Announces audit rows that could not be written
  ├── AlexClaw.Knowledge.EmbedThrottle   # Paces embedding calls against provider limits
  ├── AlexClaw.LLM.UsageTracker          # ETS owner for per-provider call counters
  ├── AlexClaw.Config.Loader             # Seeds config, loads it into the ETS cache
  ├── AlexClaw.Workflows.SkillRegistry   # ETS owner for the skill catalogue
  ├── AlexClaw.Database.EncryptCredentials  # Boot step: stops the boot on any value that does not decrypt; encrypts plain credentials
  ├── AlexClaw.Config.SecretUpgrade     # Boot step: moves secret settings still in the database into OpenBao (read back before the copy is emptied)
  ├── AlexClaw.Webhooks.GitHubSecret   # The GitHub webhook secret, resolved once from OpenBao and again after a rotation
  ├── AlexClaw.Workflows.Registry        # Tracks in-flight workflow runs
  ├── AlexClaw.LogBuffer                 # In-memory ring buffer for recent logs
  ├── AlexClaw.Google.TokenManager       # OAuth2 token lifecycle (cache + refresh)
  ├── AlexClaw.RateLimiter.Server        # Login rate limiting (ETS + periodic purge)
  ├── AlexClaw.Auth.SkillRateLimiter     # Per-skill call rate limiting
  ├── AlexClaw.Auth.ChallengeStore       # Owns the pending-2FA table
  ├── AlexClaw.Auth.RunApproval          # Single-use approvals of runs that require 2FA
  ├── AlexClaw.Auth.Elevation            # Owns the admin elevation table
  ├── AlexClaw.Auth.CodeAttempts         # Owns the 2FA code attempt counters
  ├── AlexClaw.Auth.Sessions             # Sweeps expired admin logins
  ├── Registry (AlexClaw.CircuitBreakerRegistry)  # Per-skill breaker registry
  ├── AlexClaw.Skills.CircuitBreakerSupervisor  # DynamicSupervisor
  ├── AlexClaw.SkillSupervisor           # DynamicSupervisor — skill worker processes
  ├── AlexClaw.Skills.ForgeGuard         # One skill generation at a time
  ├── AlexClaw.LLM.LocalLock             # One local model call at a time
  ├── AlexClaw.WebAutomation.PlayLock    # One web-automation play at a time
  ├── AlexClaw.Reasoning.Supervisor      # DynamicSupervisor — reasoning sessions
  ├── AlexClaw.MCP.Server                # MCP server (Streamable HTTP)
  ├── AlexClaw.Cluster.Manager           # Node registration and remote triggers
  ├── AlexClaw.Scheduler                 # Quantum cron scheduler
  ├── AlexClaw.Gateway.Supervisor        # The chat gateways (see below)
  ├── AlexClawWeb.Endpoint               # Phoenix HTTP server (admin UI)
  ├── AlexClaw.UpdateChecker             # Periodic release check
  │
  └── background workers, when :start_background_workers is true:
      └── AlexClaw.Workflows.SchedulerSync  # Syncs DB schedules into Quantum
```

## Key Design Decisions

**Flat hierarchy** — every child is a sibling under one supervisor. That is
deliberate for a single-operator agent, where simplicity is worth more than a
restart strategy nobody will reason about at 3am.

**Gateways under their own supervisor** — the root supervisor uses the default
restart intensity, three restarts in five seconds; a child that crashes faster
than that stops the whole application. A gateway handles messages that arrive
from outside, so it is the child most exposed to that. `AlexClaw.Gateway.Supervisor`
(`one_for_one`) holds `AlexClaw.Gateway.Telegram` and, when
`:start_background_workers` is true, `AlexClaw.Gateway.DiscordStarter`. A
gateway crashing repeatedly uses up this supervisor's intensity; the root then
restarts the gateway supervisor once, and no other child is touched. The
Telegram gateway also handles each incoming update in isolation: an update whose
handling fails is logged and acknowledged, never delivered again.

**The OpenBao client under its own supervisor** — `AlexClaw.Vault.Supervisor`
holds `AlexClaw.Vault`, which logs in to OpenBao and serves every secret read,
write, encryption and decryption. OpenBao unreachable or sealed is a value its
callers receive (`{:error, :vault_unavailable}`), not a crash; a client that
crashes repeatedly uses up this supervisor's restarts, and the root restarts
the branch without touching any other child. See [OpenBao](openbao.md).

**Task.Supervisor for async work** — workflow executions, background embeddings
and notification sends run under `AlexClaw.TaskSupervisor`. A crash there is
reported and supervised rather than silently lost. `AlexClaw.TaskSupervisor` is
a registered process name, not a module.

**DynamicSupervisors** — `SkillSupervisor`, `CircuitBreakerSupervisor` and
`Reasoning.Supervisor` manage a variable number of children: one per running
skill, per circuit breaker, and per reasoning session.

**One local model call at a time.** A local model server holds its weights in
the host's memory, so work that drives one must not run twice at once.
`AlexClaw.Lock` holds a single holder and releases when that process exits;
three are started from it. `AlexClaw.LLM.LocalLock` is taken around every
completion sent to a `local`-tier provider — a second is refused with
`{:error, :local_model_busy}`, and embeddings are not held there.
`AlexClaw.Skills.ForgeGuard` is taken by the Forge page and the Coder skill
around a whole generation, which is also capped at five attempts and at
`forge.time_budget_seconds` across all of them. `AlexClaw.WebAutomation.PlayLock`
is taken around every web-automation play, so a second is refused with
`{:error, :busy}` before any request reaches the sidecar. None queues: a queued
run only brings the same load back later.

**Every ETS table has a supervised owner.** `Config.Loader`, `SkillRegistry`,
`UsageTracker`, `RateLimiter.Server`, `LogBuffer`, `ChallengeStore`,
`Elevation`, `CodeAttempts` and `TokenManager` each create theirs in `init/1`, directly or through an
initialiser they call. A table dies with its owner and is rebuilt on restart,
so no state outlives the process responsible for it — and none is owned by a
process nobody chose.

That last part was not always true. Three tables were created on first use, by
whichever caller reached them first: a LiveView that raised a 2FA challenge
owned `:totp_challenges` until the tab closed. A test now fails the build if
an `:ets.new` appears that no supervised `init/1` reaches.

The two tables holding security state — `:totp_challenges` and
`:google_oauth_states` — are `:protected` rather than `:public`. Their owner
writes and everything else reads, so a write from elsewhere raises instead of
quietly succeeding. Read-modify-writes on them happen inside the owner as a
single call: counting a failed 2FA attempt, and redeeming a one-shot OAuth
CSRF state.

**A lost audit row is never silent.** When an audit row cannot be written, the
event is logged at error level in the process that tried to write it.
`AlexClaw.Auth.AuditLoss` then tells the operator over the gateways: the first
loss at once, later ones counted and sent together at most once a minute, so a
database outage produces one notice a minute rather than one per audited
action. It starts right after `TaskSupervisor`, before anything that audits.

**A login is decided on the server.** Every live admin login is a row in
`admin_sessions`, which every node reads: opened when the password is
accepted, closed at logout, valid for eight hours, and only while the admin
password is the one it was opened with. Both the authentication plug and the
`on_mount` hook of every admin LiveView ask `AlexClaw.Auth.Sessions`, rather
than trusting the session a request carries — a LiveView mounts from a copy of
the session signed into the page, which outlives logout. Logout also
broadcasts `"disconnect"` on the login's `live_socket_id`, closing its open
pages. The process itself only sweeps expired rows, every ten minutes.

## Conditional children

Two children start only when `:start_background_workers` is true, which the test
environment sets to false so the suite does not run cron jobs or open a Discord
socket: `Workflows.SchedulerSync` under the root, and `Gateway.DiscordStarter`
under the gateway supervisor.

`Gateway.DiscordStarter` is the supervised child; it is not the Discord
connection. It reads the Discord settings from configuration, and starts Nostrum
only if the gateway is enabled, a token is present, and this node is the one
assigned to run the bot. `AlexClaw.Gateway.Discord` — the Nostrum consumer that
receives messages — is then started underneath it.

Discord is configured from **Admin > Config**, not from the environment. See
[Configuration](../getting-started/configuration.md).

In a cluster, `telegram.node` and `discord.node` decide which single node runs
each bot. See [Multi-Node Clustering](clustering.md).
