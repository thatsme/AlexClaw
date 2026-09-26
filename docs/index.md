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
# In .env: DATABASE_OWNER_PASSWORD, DATABASE_PASSWORD, SECRET_KEY_BASE,
# ADMIN_PASSWORD, CLUSTER_COOKIE and TELEGRAM_CHAT_ID.
mkdir -p openbao/unseal
head -c 32 /dev/urandom > openbao/unseal/key && chmod 0440 openbao/unseal/key
docker compose up -d
docker compose run --rm openbao-init   # once: prints the recovery key
```

Open [http://localhost:5001](http://localhost:5001) and log in with `ADMIN_PASSWORD`.
Set up 2FA (Services page), then on the Config page enter the Telegram bot
token, an LLM API key (Gemini's is free) and `telegram.owner_user_id` — the bot
answers only that user, in `telegram.chat_id`. Send `/ping` to the bot to
verify.

The unseal key file encrypts every secret: losing it loses them all. The full
first-start procedure, including the file ownership Linux needs, is in
[OpenBao](architecture/openbao.md#first-start).

Full setup walkthrough: [Installation](getting-started/installation.md)

---

## Feature Overview

| Area | What it does |
|---|---|
| **Multi-Model LLM Router** | Tier-based routing (`light`/`medium`/`heavy`/`local`) with priority ordering, daily usage tracking, and automatic fallback |
| **Workflow Engine** | Linear pipelines with conditional branching, per-step circuit breaking, and full run history |
| **Persistent Memory** | PostgreSQL + pgvector, hybrid semantic + keyword search, async background embedding |
| **Dynamic Skills** | Upload `.ex` skill modules at runtime — contained to an allowlist, permission-checked, 2FA-approved, integrity-checksummed |
| **Forge** | Generates new skills from a goal, with a local or a chosen provider. Contained code within the unattended permissions loads at once; more permissions wait for a 2FA code; calls outside the allowlist never load |
| **Secrets in OpenBao** | Every credential in a bundled OpenBao, bound to its destination; the database holds references |
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
- A place to keep OpenBao's unseal key file and recovery key offline (the key file is made before the first start, the recovery key is printed at it)
