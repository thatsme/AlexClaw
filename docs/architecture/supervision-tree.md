# Supervision Tree

AlexClaw uses a flat `one_for_one` supervision strategy. Each child is
independent — a crash in one does not restart the others.

```
AlexClaw.Application (one_for_one)
  ├── AlexClaw.Repo                      # PostgreSQL connection pool (Ecto)
  ├── Phoenix.PubSub (AlexClaw.PubSub)   # Config changes, skill list, run events
  ├── Task.Supervisor (AlexClaw.TaskSupervisor)  # Supervised fire-and-forget work
  ├── AlexClaw.Knowledge.EmbedThrottle   # Paces embedding calls against provider limits
  ├── AlexClaw.LLM.UsageTracker          # ETS owner for per-provider call counters
  ├── AlexClaw.Config.Loader             # Seeds config, loads it into the ETS cache
  ├── AlexClaw.Workflows.SkillRegistry   # ETS owner for the skill catalogue
  ├── AlexClaw.Workflows.Registry        # Tracks in-flight workflow runs
  ├── AlexClaw.LogBuffer                 # In-memory ring buffer for recent logs
  ├── AlexClaw.Google.TokenManager       # OAuth2 token lifecycle (cache + refresh)
  ├── AlexClaw.RateLimiter.Server        # Login rate limiting (ETS + periodic purge)
  ├── AlexClaw.Auth.SkillRateLimiter     # Per-skill call rate limiting
  ├── Registry (AlexClaw.CircuitBreakerRegistry)  # Per-skill breaker registry
  ├── AlexClaw.Skills.CircuitBreakerSupervisor  # DynamicSupervisor
  ├── AlexClaw.SkillSupervisor           # DynamicSupervisor — skill worker processes
  ├── AlexClaw.Reasoning.Supervisor      # DynamicSupervisor — reasoning sessions
  ├── AlexClaw.MCP.Server                # MCP server (Streamable HTTP)
  ├── AlexClaw.Cluster.Manager           # Node registration and remote triggers
  ├── AlexClaw.Scheduler                 # Quantum cron scheduler
  ├── AlexClaw.Gateway.Telegram          # Telegram long-polling bot
  ├── AlexClawWeb.Endpoint               # Phoenix HTTP server (admin UI)
  ├── AlexClaw.UpdateChecker             # Periodic release check
  │
  └── background workers, when :start_background_workers is true:
      ├── AlexClaw.Workflows.SchedulerSync  # Syncs DB schedules into Quantum
      └── AlexClaw.Gateway.DiscordStarter   # Starts Nostrum if Discord is configured
```

## Key Design Decisions

**Flat hierarchy** — every child is a sibling under one supervisor. That is
deliberate for a single-operator agent, where simplicity is worth more than a
restart strategy nobody will reason about at 3am.

**Task.Supervisor for async work** — workflow executions, background embeddings
and notification sends run under `AlexClaw.TaskSupervisor`. A crash there is
reported and supervised rather than silently lost. `AlexClaw.TaskSupervisor` is
a registered process name, not a module.

**DynamicSupervisors** — `SkillSupervisor`, `CircuitBreakerSupervisor` and
`Reasoning.Supervisor` manage a variable number of children: one per running
skill, per circuit breaker, and per reasoning session.

**Some ETS owners are supervised processes** — `Config.Loader`, `SkillRegistry`,
`UsageTracker`, `RateLimiter.Server` and `LogBuffer` each create their table in
`init/1`. The table dies with its owner and is rebuilt on restart, which is the
property you want: no cache outlives the process responsible for it.

**Three tables do not work this way.** `:totp_challenges`,
`:google_oauth_state` and the query-rewriter cache are created lazily by
whichever process calls them first, which can be a LiveView or a short-lived
task. Such a table dies when that process does, taking its contents with it.
For the rewriter cache that costs a cold start; for the other two it loses
pending 2FA challenges and in-flight OAuth state. This is a known defect, not a
design — see the batch 2d plan.

## Conditional children

Two children start only when `:start_background_workers` is true, which the test
environment sets to false so the suite does not run cron jobs or open a Discord
socket.

`Gateway.DiscordStarter` is the supervised child; it is not the Discord
connection. It reads the Discord settings from configuration, and starts Nostrum
only if the gateway is enabled, a token is present, and this node is the one
assigned to run the bot. `AlexClaw.Gateway.Discord` — the Nostrum consumer that
receives messages — is then started underneath it.

Discord is configured from **Admin > Config**, not from the environment. See
[Configuration](../getting-started/configuration.md).

In a cluster, `telegram.node` and `discord.node` decide which single node runs
each bot. See [Multi-Node Clustering](clustering.md).
