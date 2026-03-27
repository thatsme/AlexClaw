# AlexClaw 🦇

**A BEAM-native personal autonomous AI agent built on Elixir/OTP.**

AlexClaw monitors the world — RSS feeds, GitHub repositories, Google services, arbitrary APIs — accumulates knowledge, executes workflows autonomously on schedule, and communicates with its owner via Telegram or Discord. Every task is routed to the cheapest available LLM that satisfies the required reasoning tier, including fully local models.

> Designed as a single-user personal agent. Not a platform. Not a marketplace. One codebase, fully auditable, running on your infrastructure.

---

## Why AlexClaw?

- **BEAM-native** — OTP supervision, concurrency, and fault tolerance are the runtime, not bolted on. A failed RSS fetch cannot crash a concurrent research query.
- **Cost-aware** — tier-based LLM routing maximises free tiers across providers. Fully local (zero API cost) deployments are supported.
- **Runtime-configurable** — all settings live in PostgreSQL, cached in ETS, editable via admin UI without restart.
- **Single-user, fully auditable** — no multi-tenant complexity, no marketplace, no platform overhead.

---

## Quick Start

```bash
git clone https://github.com/thatsme/AlexClaw.git
cd AlexClaw
cp .env.example .env
# Edit .env — set DATABASE_PASSWORD, SECRET_KEY_BASE, ADMIN_PASSWORD,
# TELEGRAM_BOT_TOKEN, and at least one LLM API key (GEMINI_API_KEY is free)
docker compose up -d
```

Open [http://localhost:5001](http://localhost:5001) and log in with your `ADMIN_PASSWORD`.
Send `/ping` to your Telegram bot to verify. That's it.

Full setup walkthrough: [Installation](getting-started/installation.md)

---

## Feature Overview

| Area | What it does |
|---|---|
| **Multi-Model LLM Router** | Tier-based routing (`light`/`medium`/`heavy`/`local`) with priority ordering, daily usage tracking, and automatic fallback |
| **Workflow Engine** | Linear pipelines with conditional branching, per-step circuit breaking, and full run history |
| **Persistent Memory** | PostgreSQL + pgvector, hybrid semantic + keyword search, async background embedding |
| **Dynamic Skills** | Hot-load `.ex` skill modules at runtime — permission-sandboxed, 2FA-gated, integrity-checksummed |
| **Coder Skill** | Local LLM generates new skills from natural language. Zero cloud cost |
| **Multi-Gateway** | Telegram + Discord simultaneously. Responses route back to the originating transport |
| **Multi-Node Clustering** | Multiple BEAM nodes share a database and exchange workflow outputs over Erlang distribution |
| **OTP Circuit Breaker** | Per-skill breaker with automatic half-open recovery. No external dependencies |

---

## Architecture in One Diagram

```
Telegram ──> TelegramGateway ──┐
Discord  ──> DiscordGateway  ──┴──> Dispatcher ──> Skills
                                         │              │
                               Workflows.Executor    SkillSupervisor
                                         │         (DynamicSupervisor)
                                    LLM Router
                          (Gemini / Anthropic / Ollama / LM Studio)
                                         │
                           ┌─────────────┴─────────────┐
                        Memory                       Config
                 (pgvector + embeddings)         (DB + ETS + PubSub)
```

→ [Full architecture documentation](architecture/overview.md)

---

## Requirements

- Docker and Docker Compose v2
- 2 GB RAM minimum
- A Telegram bot token (from [@BotFather](https://t.me/BotFather))
- At least one LLM provider — [Gemini API key](https://ai.google.dev/) is free and takes 2 minutes
