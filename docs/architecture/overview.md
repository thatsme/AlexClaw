# Architecture Overview

AlexClaw is a BEAM-native personal autonomous AI agent built on Elixir/OTP.

## Design Principles

- **BEAM-native** — supervision, concurrency, and fault tolerance are the runtime, not bolted on
- **Single-user** — one operator, one codebase, fully auditable. Not a platform
- **Cost-aware** — multi-model LLM router maximizes free tiers across providers
- **Runtime-configurable** — all settings live in PostgreSQL, cached in ETS, editable via admin UI without restart

## Component Diagram

```
Telegram <──> TelegramGateway ──┐
Discord  <──> DiscordGateway  ──┼──> Router ──> Dispatcher ──> Skills
MCP Client <──> MCP.Server ────┘
                                │
Admin UI (Chat) ──────> SkillSupervisor ──> Dynamic Skills
                       (DynamicSupervisor)
Admin UI (Reasoning) ──> Reasoning.Loop ──> Skills (whitelisted)
                        (DynamicSupervisor)
                                │
                 ┌──────────────┼──────────────┐
                 ▼              ▼              ▼
           LLM Router     Memory/Knowledge   Workflows
           (tier-based)   (pgvector)         (cron + on-demand)
```

## Core Components

| Component | Module | Description |
|---|---|---|
| [Gateway Layer](gateway.md) | `AlexClaw.Gateway.*` | Multi-transport messaging (Telegram, Discord, MCP) |
| Dispatcher | `AlexClaw.Dispatcher` | Deterministic pattern-matching command router |
| [LLM Router](llm-router.md) | `AlexClaw.LLM` | Tier-based multi-provider routing with usage tracking |
| [Workflow Engine](workflow-engine.md) | `AlexClaw.Workflows.*` | Linear pipelines with conditional branching |
| [Reasoning Loop](reasoning-loop.md) | `AlexClaw.Reasoning.*` | Autonomous plan-execute-evaluate agent cycle |
| [Memory & Knowledge](memory.md) | `AlexClaw.Memory`, `AlexClaw.Knowledge` | pgvector semantic search with hybrid retrieval |
| [Supervision Tree](supervision-tree.md) | `AlexClaw.Application` | OTP supervision hierarchy |
| [Clustering](clustering.md) | `AlexClaw.Cluster.Manager` | Multi-node BEAM distribution |
| Config | `AlexClaw.Config` | DB-backed, ETS-cached runtime configuration |
| Circuit Breaker | `AlexClaw.Skills.CircuitBreaker` | Per-skill fault isolation with auto-recovery |

## Data Flow

A typical workflow execution:

1. **Trigger** — cron schedule, Telegram command (`/run`), Admin UI, or MCP tool call
2. **Executor** — walks the step graph sequentially
3. **Per step** — resolves skill from registry, checks circuit breaker, executes in supervised task
4. **LLM calls** — routed by tier to cheapest available provider
5. **Results** — stored in memory/knowledge, step results persisted to DB
6. **Delivery** — notify skills send output to Telegram/Discord
7. **Audit** — run history, step durations, and outcomes recorded

## Technology Stack

| Layer | Technology |
|---|---|
| Language | Elixir 1.19 / OTP 28 |
| Web framework | Phoenix 1.8 + LiveView |
| HTTP server | Bandit |
| Database | PostgreSQL 16 + pgvector |
| Cron | Quantum |
| MCP | anubis_mcp (Streamable HTTP) |
| Discord | Nostrum |
| Container | Docker + Docker Compose |
