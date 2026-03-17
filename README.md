# AlexClaw 🦇

A BEAM-native personal autonomous AI agent built on Elixir/OTP.

AlexClaw monitors the world (RSS feeds, web sources, GitHub repositories, APIs), accumulates knowledge, executes workflows autonomously on schedule, and communicates with its owner via Telegram. It routes every task to the cheapest available LLM that satisfies the required reasoning tier — including fully local models.

> **Designed as a single-user personal agent.** Not a platform. Not a marketplace. One codebase, fully auditable, running on your infrastructure.

"I didn't plan most of this. I just kept solving the next problem."

![AlexClaw Dashboard](docs/screenshot/dashboard.jpg)

---

## Features

### Core

- **Multi-Model LLM Router** — Tier-based routing (`light` / `medium` / `heavy` / `local`) with priority-based selection. All providers (cloud and local) are stored in PostgreSQL and fully manageable from the admin UI. Tracks daily usage per provider in ETS. Ships with default providers (Gemini, Claude, Ollama, LM Studio) seeded on first boot — add, remove, or reconfigure any provider at runtime.
- **Workflow Engine** — Define multi-step pipelines combining skills and LLM transforms. Each step passes output to the next. Runs on schedule (cron) or on demand. Full run history with step-level results in the admin UI.
- **Telegram Gateway** — Bidirectional communication via long-polling. Command routing is deterministic pattern-matching — no LLM involved in dispatch.
- **Runtime Configuration** — All settings (API keys, prompts, limits, personas) are stored in PostgreSQL, cached in ETS, and editable at runtime via the admin UI. No restart required for any config change.
- **Persistent Memory** — PostgreSQL + pgvector for knowledge storage. Deduplication by URL. Semantic search via cosine similarity with keyword fallback.
- **Cron Scheduler** — Quantum-based. Jobs defined in config or DB.

### Skills

![AlexClaw Skills](docs/screenshot/skills.jpg)

| Skill | Description |
|---|---|
| `rss_collector` | Fetch RSS feeds, deduplicate, score relevance via LLM, notify |
| `web_search` | Search the web and synthesize answers |
| `web_browse` | Fetch and summarize a URL, or answer questions about it |
| `research` | Deep research with memory context |
| `conversational` | Free-text LLM conversation |
| `telegram_notify` | Send a Telegram message as a workflow step |
| `llm_transform` | Run a prompt template through the LLM (workflow glue step) |
| `api_request` | Make an authenticated HTTP request |
| `github_security_review` | Fetch PR/commit diff, run LLM security analysis |
| `google_calendar` | Fetch upcoming Google Calendar events |
| `google_tasks` | Manage Google Tasks lists and items |
| `web_automation` | Browser automation via headless Playwright sidecar (**experimental**) |

### GitHub Security Review

AlexClaw can review pull requests and commits for security issues:

- Run as a workflow step with per-workflow repo, token, and security focus
- Trigger manually via Telegram: `/github pr owner/repo 42`
- GitHub webhook endpoint available (`/webhooks/github`) with HMAC-SHA256 verification
- Diff truncation at 24KB — works with local models
- Structured output: RISK LEVEL, FINDINGS, SUMMARY, RECOMMENDATION

### Security

- **Session-based authentication** — all routes except `/login` require an authenticated session
- **Two-Factor Authentication (2FA)** — TOTP-based via authenticator apps. Setup and confirmation via Telegram (`/setup 2fa`, `/confirm 2fa`)
- **Built-in login rate limiting** — ETS-based, configurable max attempts and block duration, adjustable at runtime without restart
- **HMAC-SHA256 webhook verification** — GitHub webhook endpoint uses `Plug.Crypto.secure_compare` for timing-safe signature validation
- **Encryption at rest** — API keys and tokens are AES-256-GCM encrypted in PostgreSQL, decrypted transparently at runtime
- **Sensitive key masking** — API keys and tokens show partial values in the admin UI

---

## Architecture

```
Telegram <──> Gateway <──> Dispatcher ──> Skills
                                │
                          SkillSupervisor
                         (DynamicSupervisor)
                                │
                 ┌──────────────┼──────────────┐
              RSS            Research        GitHub
             Skill            Skill       Security Review
                                │
                           LLM Router
                    (Gemini / Anthropic / Ollama / LM Studio)
                                │
                    ┌───────────┴───────────┐
                 Memory                  Config
              (pgvector)             (DB + ETS + PubSub)

GitHub Webhook ──> WebhookController ──> GitHubSecurityReview
Scheduler (Quantum) ──> Workflows.Executor ──> Skills
Phoenix LiveView Admin ──> all of the above
```

Every skill runs as an isolated OTP process. Crashes are contained and supervised. The `Dispatcher` is deterministic pattern-matching — no LLM token cost for routing.

See [ALEXCLAW_ARCHITECTURE.md](ALEXCLAW_ARCHITECTURE.md) for the full design document.

---

## Quick Start

```bash
git clone https://github.com/thatsme/AlexClaw.git
cd AlexClaw
cp .env.example .env
# Edit .env — set DATABASE_PASSWORD, SECRET_KEY_BASE, ADMIN_PASSWORD,
# TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, and at least one LLM API key
docker compose up -d
```

Open [http://localhost:5001](http://localhost:5001) and log in with your `ADMIN_PASSWORD`.
Send `/ping` to your Telegram bot to verify connectivity.

For detailed setup instructions, Telegram bot setup, and local model configuration, see **[INSTALLATION.md](INSTALLATION.md)**.

---

## Configuration

All configuration is managed at runtime through the admin UI (`/config`). On first boot, values are seeded from environment variables. After that, changes are made in the UI — no restart needed.

### Minimum required environment variables

| Variable | Description |
|---|---|
| `DATABASE_PASSWORD` | PostgreSQL password |
| `SECRET_KEY_BASE` | Phoenix session secret (`mix phx.gen.secret`) |
| `ADMIN_PASSWORD` | Web interface login password |
| `TELEGRAM_BOT_TOKEN` | From @BotFather |
| `TELEGRAM_CHAT_ID` | Your Telegram chat ID |

### LLM providers (at least one required)

| Variable | Description |
|---|---|
| `GEMINI_API_KEY` | Google Gemini (free tier available) |
| `ANTHROPIC_API_KEY` | Anthropic Claude |
| `OLLAMA_ENABLED=true` + `OLLAMA_HOST` | Local Ollama instance |
| `LMSTUDIO_ENABLED=true` + `LMSTUDIO_HOST` | Local LM Studio instance |

All other settings (GitHub tokens, webhook secrets, LLM limits, prompts, skill config) are managed at runtime through the Config UI after first boot.

See `.env.example` for the full list of bootstrap variables.

---

## LLM Tier System

| Tier | Default providers | Typical use |
|---|---|---|
| `light` | Gemini Flash, Claude Haiku | RSS scoring, classification, simple tasks |
| `medium` | Gemini Pro, Claude Sonnet | Summarization, research, security review |
| `heavy` | Claude Opus | Deep reasoning (explicit only) |
| `local` | LM Studio, Ollama | Privacy-sensitive content, offline use, zero cost |

All providers live in the database and can be added, removed, or reconfigured from the admin UI. The defaults above are seeded on first boot. The router selects by priority within each tier (lower priority number = preferred), tracks daily usage, and falls back to the next available provider. A fully local deployment with no API keys is supported — enable a local provider and all tiers will fall back to it.

---

## Telegram Commands

| Command | Description |
|---|---|
| `/ping` | Check if the bot is alive |
| `/status` | System status (uptime, memory, active skills) |
| `/skills` | List registered skills |
| `/llm` | Show LLM provider status |
| `/workflows` | List all workflows with status and ID |
| `/run <id or name>` | Run a workflow on demand |
| `/research <query>` | Deep research with memory context |
| `/search <query>` | Web search and synthesis |
| `/web <url>` | Fetch and summarize a URL |
| `/web <url> <question>` | Answer a question about a URL |
| `/github pr <owner/repo> [number]` | Security review a PR |
| `/github commit <owner/repo> <sha>` | Security review a commit |
| `/events` | Show today's Google Calendar events |
| `/events add <title> <date> <time>` | Create a calendar event |
| `/tasks` | List Google Tasks |
| `/tasklists` | List your task lists by name |
| `/task add <title>` | Add a task to Google Tasks |
| `/record <url>` | Start browser recording session (web-automator) |
| `/record stop <session_id>` | Stop a recording session |
| `/automations` | List automation resources |
| `/setup 2fa` | Set up two-factor authentication |
| `/confirm 2fa <code>` | Confirm 2FA with authenticator code |
| `/google auth` | Start Google OAuth flow via Telegram |
| `/help` | Show all commands |
| _any text_ | Free-text conversation |

---

## Admin UI

![AlexClaw Workflows](docs/screenshot/workflows.jpg)

| Page | Description |
|---|---|
| Dashboard | System status, recent activity |
| Workflows | Create/edit/run multi-step pipelines, view run history |
| Skills | Available skills and status |
| Scheduler | Cron jobs and scheduled workflows |
| LLM | Provider status and usage |
| Feeds | RSS feed management |
| Resources | Shared resources for workflows |
| Memory | Browse and search stored knowledge |
| Database | Schema browser and backup download |
| Config | Runtime configuration editor |

---

## Project Structure

```
lib/
  alex_claw/
    config/          # Runtime config (DB + ETS + PubSub broadcast)
    llm/             # LLM router, usage tracker, provider schema
    memory/          # Memory entry schema
    skills/          # All skill modules
    workflows/       # Executor, scheduler sync, step/run schemas
    dispatcher.ex    # Deterministic message routing
    gateway.ex       # Telegram bot
    identity.ex      # Agent persona and system prompts
    llm.ex           # Multi-model router
    memory.ex        # Knowledge store
    rate_limiter.ex  # ETS-based login rate limiting
    scheduler.ex     # Quantum cron scheduler
  alex_claw_web/
    controllers/     # Auth, database backup, GitHub webhook
    live/admin_live/ # LiveView admin pages
    plugs/           # RequireAuth, RateLimit, RawBodyReader
priv/repo/
  migrations/        # All DB migrations
  seeds/             # Example workflow seeds
```

---

## Known Limitations

- **Semantic search is not yet wired up.** The pgvector column exists in the memory table, but the embedding integration is a stub — `Memory.embed/2` returns nil. Memory deduplication and keyword search work. Semantic search via vector similarity is on the roadmap.
- **Single-user only.** There is no multi-user access control. The authentication model assumes one trusted operator.
- **Sensitive config encrypted at rest.** API keys and tokens are AES-256-GCM encrypted in PostgreSQL using `SECRET_KEY_BASE` as key material. Changing `SECRET_KEY_BASE` requires re-entering all API keys. See [SECURITY.md](SECURITY.md) for details.
- **Web Automator is experimental.** The browser automation sidecar (`web_automation` skill) is under heavy development. APIs, config format, and recording workflow may change without notice.

---

## Security

See [SECURITY.md](SECURITY.md) for the full security policy and deployment hardening guidance.

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution guidelines and [CLA.md](CLA.md) for the Contributor License Agreement.

---

## License

Copyright 2026 Alessio Battistutta — Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for details.
