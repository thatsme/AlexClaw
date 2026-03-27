# Supervision Tree

AlexClaw uses a flat `one_for_one` supervision strategy. Each child is independent — a crash in one component does not affect others.

```
AlexClaw.Application (one_for_one)
  ├── AlexClaw.Repo                    # PostgreSQL connection pool (Ecto)
  ├── Phoenix.PubSub                   # Config change broadcast
  ├── Task.Supervisor (TaskSupervisor) # Supervised fire-and-forget tasks
  ├── AlexClaw.LLM.UsageTracker       # ETS owner for LLM call counters
  ├── AlexClaw.Config.Loader          # Seeds config from env → DB, loads into ETS
  ├── AlexClaw.LogBuffer              # In-memory ring buffer for recent logs
  ├── AlexClaw.Google.TokenManager    # Google OAuth2 token lifecycle
  ├── AlexClaw.RateLimiter.Server     # Login rate limiting (ETS + periodic purge)
  ├── Registry (CircuitBreakerRegistry)
  ├── CircuitBreakerSupervisor        # DynamicSupervisor — per-skill breakers
  ├── AlexClaw.SkillSupervisor        # DynamicSupervisor — skill workers
  ├── AlexClaw.MCP.Server             # MCP server (Streamable HTTP)
  ├── AlexClaw.Cluster.Manager        # Node discovery and remote triggers
  ├── AlexClaw.Scheduler              # Quantum cron scheduler
  ├── AlexClaw.Workflows.SchedulerSync # Syncs DB schedules into Quantum
  ├── AlexClaw.Gateway.Telegram       # Telegram long-polling bot
  ├── AlexClaw.Gateway.Discord        # Discord WebSocket (conditional)
  └── AlexClawWeb.Endpoint            # Phoenix HTTP server
```

## Key Design Decisions

**Flat hierarchy** — all children are siblings under one supervisor. This is intentional for a single-user agent where simplicity outweighs complex restart strategies.

**Task.Supervisor for async work** — all workflow executions, background embeddings, and fire-and-forget tasks run under `AlexClaw.TaskSupervisor`. Crashes are reported and supervised, not silently lost.

**DynamicSupervisors** — `SkillSupervisor` and `CircuitBreakerSupervisor` manage variable numbers of child processes (one per active skill execution or circuit breaker).

**Conditional children** — the Discord gateway only starts when `DISCORD_BOT_TOKEN` is set. In cluster mode, gateways only start on their assigned node.
