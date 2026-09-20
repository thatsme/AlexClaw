# Architecture Overview

AlexClaw is a BEAM-native personal autonomous AI agent built on Elixir/OTP.

These pages describe **roles and flows**: what each part is for, and how a
message becomes an action. They deliberately do not restate behaviour that is
defined elsewhere — where a security boundary, a permission, a configuration key
or a dependency version matters, the page says so in a sentence and links to the
document that owns it. One statement, one home.

| Subject | Owner |
|---|---|
| Security boundaries, 2FA, skill containment, MCP restrictions | [SECURITY.md](https://github.com/thatsme/AlexClaw/blob/main/SECURITY.md) |
| What a skill may call, and what each permission grants | [Skill API Reference](../skills/skill-api.md) |
| Settings, categories, environment variables | [Configuration](../getting-started/configuration.md) |
| Behaviour changes between versions | [Changelog](../reference/changelog.md) |

## Design Principles

- **BEAM-native** — supervision, concurrency, and fault tolerance are the runtime, not bolted on
- **Single-user** — one operator, one codebase, fully auditable. Not a platform
- **Cost-aware** — a multi-model LLM router maximises free tiers across providers
- **Runtime-configurable** — settings live in PostgreSQL, cached in ETS, editable from the admin UI without a restart

## Component Diagram

```
Telegram <──> Gateway.Telegram ──┐
Discord  <──> Gateway.Discord  ──┼──> Gateway.Router ──> Dispatcher ──> Skills
MCP client <──> MCP.Server ──────┘                          │
                                                            │
Admin UI (Chat) ─────────> Conversational ──────────────────┤
Admin UI (Reasoning) ────> Reasoning.Loop ──> Skills (whitelisted)
Cron / on-demand ────────> Workflows.Executor ──> Skills
                                                            │
                         ┌──────────────┬─────────────┬─────┴────────┐
                         ▼              ▼             ▼              ▼
                    LLM Router    Memory/Knowledge  SkillAPI    Auth layer
                   (tier-based)      (pgvector)   (permissions)  (Gate, policies)
```

## Core Components

| Component | Module | Role |
|---|---|---|
| [Gateway Layer](gateway.md) | `AlexClaw.Gateway.*` | Multi-transport messaging, and which node owns a bot |
| Dispatcher | `AlexClaw.Dispatcher` | Deterministic pattern-matching command router |
| Gate | `AlexClaw.Auth.Gate` | One place that decides whether an action needs a second factor, used by both the gateway and the admin UI |
| [LLM Router](llm-router.md) | `AlexClaw.LLM` | Tier-based provider routing. `LLM.Behaviour` and `LLM.Real` split the seam so tests substitute a mock |
| [Workflow Engine](workflow-engine.md) | `AlexClaw.Workflows.Executor` | Walks the step graph, routes branches, records outcomes |
| LLM step | `AlexClaw.Workflows.LLMTransform` | The generic "run a prompt over the previous step's output" step |
| [Skills](skills.md) | `AlexClaw.Skills.*` | The catalogue, how a skill is written, and how generated code is judged before it loads |
| [Reasoning Loop](reasoning-loop.md) | `AlexClaw.Reasoning.*` | Autonomous plan–execute–evaluate cycle |
| [Memory & Knowledge](memory.md) | `AlexClaw.Memory`, `AlexClaw.Knowledge` | pgvector semantic search, chunking, hybrid retrieval and fallback |
| [Supervision Tree](supervision-tree.md) | `AlexClaw.Application` | What runs, and what happens when it crashes |
| [Clustering](clustering.md) | `AlexClaw.Cluster.Manager` | Multi-node BEAM distribution |
| Config | `AlexClaw.Config` | DB-backed, ETS-cached runtime configuration. `Config.Crypto` encrypts sensitive values; `Config.Seeder` writes the defaults on first boot |
| Circuit Breaker | `AlexClaw.Skills.CircuitBreaker` | Per-skill fault isolation with auto-recovery |

## Data Flow

A typical workflow execution:

1. **Trigger** — cron schedule, a gateway command, the admin UI, or an MCP tool call
2. **Gate** — actions marked as requiring a second factor raise a challenge first
3. **Executor** — walks the step graph sequentially, carrying each step's output to the next
4. **Per step** — resolves the skill from the registry, checks its circuit breaker, runs it in a supervised task
5. **SkillAPI** — every side effect a skill causes passes a permission check
6. **LLM calls** — routed by tier to the cheapest available provider
7. **Results** — persisted per step; memory and knowledge writes are embedded asynchronously
8. **Delivery** — notify skills send output to the configured chat
9. **Audit** — run history, step durations, outcomes, and any authorization denial

## Technology Stack

| Layer | Technology |
|---|---|
| Language | Elixir 1.19 / OTP 28 |
| Web framework | Phoenix 1.8 + LiveView 1.1 |
| HTTP server | Bandit |
| Database | PostgreSQL 17 + pgvector |
| Cron | Quantum |
| MCP | anubis_mcp (Streamable HTTP) |
| Discord | Nostrum |
| Container | Docker + Docker Compose |

Exact versions are in `mix.exs` and `mix.lock`, which are the only place they
are stated.
