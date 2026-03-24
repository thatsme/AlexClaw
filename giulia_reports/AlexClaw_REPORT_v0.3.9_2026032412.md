# AlexClaw Analysis Report — v0.3.9

**Date:** 2026-03-24
**Version:** v0.3.9
**Analyzer:** Giulia v0.1.0.143 — AST + xref code intelligence for Elixir
**Graph:** AST edges + BEAM xref (target project compiled inside container)

---

## Session Summary

v0.3.9 is a source consolidation release. Changes from this session:

- **LLM split:** complexity 80 to 36, god module score 206 to 111
- **Dispatcher split:** complexity 89 to 58, 600 to 280 lines, 3 command modules extracted
- **Gateway hardened:** specs, docs, tests added
- **All unprotected hubs resolved** (0 RED, 0 YELLOW)
- **Elixir 1.19.5 guard compatibility fix**
- **116 new tests** (689 to 805)
- **58 new @spec annotations** (181 to 239, coverage 46.0% to 60.7%)
- **SkillAPI fully typed** — 30 specs added to the dynamic skill sandbox API
- **Heatmap:** Yellow 23 to 5, Green 95 to 113 (with xref-accurate graph)
- **4 Giulia bugs caught and fixed** during this session (Build 141-143)

---

## 1. Executive Summary

| Metric | Value |
|---|---|
| Source Files | 118 |
| Modules | 118 |
| Functions | 765 (394 public, 371 private) |
| Public Ratio | 51.5% |
| Types | 25 |
| Specs | 239 / 394 public (60.7%) |
| Structs | 3 |
| Callbacks | 10 |
| Graph Vertices | 883 |
| Graph Edges | 1,072 (AST + xref) |
| Connected Components | 194 |
| Circular Dependencies | 2 (xref-revealed, see Section 12) |
| Behaviour Fractures | 0 |
| Orphan Specs | 0 |
| Dead Code | 5 / 765 (0.7%) — all false positives |

**Verdict:** Clean Elixir/OTP codebase with zero behaviour fractures, zero orphan specs, and zero unprotected hubs. Spec coverage at 60.7% — the remaining 39.3% is dominated by OTP behaviour callbacks (LiveView ~107, GenServer ~52, Plug/Controller ~16) where @impl true provides the type contract. Two circular dependencies were revealed by xref — both are runtime dispatch cycles inherent to the skill invocation architecture, not structural defects.

---

## 2. Heatmap Zones

**Distribution:** 0 Red, 5 Yellow, 113 Green

### Red Zone (score >= 60)

No modules in the red zone.

### Yellow Zone (score 30-59)

| Module | Score | Complexity | Centrality | Max Coupling | Tests? |
|---|---|---|---|---|---|
| Config | 36 | 31 | 23 | 8 | Yes |
| LLM | 36 | 36 | 14 | 10 | Yes |
| Skill | 30 | 0 | 17 | 2 | Yes |
| Gateway | 30 | 0 | 16 | 2 | Yes |
| Repo | 30 | 0 | 19 | 0 | Yes |

All 5 yellow modules have tests and specs. Their scores are purely centrality-driven — these are the core infrastructure modules that everything depends on. Config (23 dependents), Repo (19), Skill (17 skill implementations), Gateway (16 message consumers), LLM (14 callers). These scores reflect architectural importance, not code quality issues.

### Green Zone (score < 30)

113 modules. All within healthy parameters.

### Test Coverage Gap Analysis

All 5 yellow modules have test files. No actionable test gaps remain in the yellow zone. The remaining untested modules in the green zone are predominantly:

**Framework boilerplate:** Application, Endpoint, Router, Layouts, Scheduler — zero or near-zero complexity, no logic to test.

**Integration-tested:** Several modules are covered by parent-level, adversarial, or cross-cutting test files rather than dedicated unit tests.

**External services:** Google.OAuth requires OAuth credentials; tested at the error-path level.

---

## 3. Top 5 Hubs

| Module | In-Degree | Out-Degree | Risk Profile |
|---|---|---|---|
| Config | 23 | 3 | Near-pure hub — application config read by 23 modules; highest blast radius |
| Dispatcher | 1 | 21 | Fan-out orchestrator — routes to 21 skills/commands; low in-degree |
| LLM | 14 | 5 | Bidirectional hub — 14 callers, 5 dependencies; central to all AI features |
| Repo | 19 | 0 | Pure hub — Ecto repo facade; structural, extremely stable |
| Gateway | 16 | 2 | Near-pure hub — messaging facade; 16 modules route through it |

xref revealed Dispatcher as a top-5 hub by total degree (22) — AST-only analysis missed its runtime fan-out to skills. Config's true in-degree is 23 (was 15 with AST only).

---

## 4. Change Risk (Top 10)

| Rank | Module | Score | Key Driver |
|---|---|---|---|
| 1 | Config | 1,275 | Centrality (23) — highest in-degree, multiplied across 12 functions |
| 2 | LLM | 1,048 | Centrality (14) with 18 functions, complexity 36 |
| 3 | Workflows.SkillRegistry | 714 | 32 functions with complexity 60, centrality 5 |
| 4 | Workflows | 702 | 21 public functions with coupling 29 to Repo |
| 5 | Skills.SkillAPI | 686 | 33 functions, complexity 102, centrality 2 (fully specced) |
| 6 | Memory | 480 | Centrality (6) across 6 public functions |
| 7 | Workflows.Executor | 425 | Complexity 54, centrality 3 from xref |
| 8 | AdminLive.Workflows | 385 | Complexity 143, zero centrality limits blast radius |
| 9 | Skills.GitHubSecurityReview | 374 | Complexity 60, centrality 2 from xref |
| 10 | Dispatcher | 333 | Complexity 58, centrality 1 but fan-out 21 |

Change risk scores are significantly higher than AST-only analysis due to xref-revealed edges increasing centrality values. Config jumped from 867 to 1,275 as its true dependency count was exposed.

---

## 5. God Modules

| Module | Functions | Complexity | Score | Centrality |
|---|---|---|---|---|
| AdminLive.Workflows | 32 | 143 | 318 | 0 |
| Skills.SkillAPI | 33 | 102 | 243 | 2 |
| Workflows.SkillRegistry | 32 | 60 | 167 | 5 |
| Skills.GitHubSecurityReview | 26 | 60 | 152 | 2 |
| Config | 12 | 31 | 143 | 23 |
| Workflows.Executor | 20 | 54 | 137 | 3 |
| LLM | 18 | 36 | 132 | 14 |
| Dispatcher | 1 | 58 | 120 | 1 |
| Skills.RSSCollector | 17 | 45 | 107 | 0 |
| LLM.Client | 13 | 44 | 104 | 1 |

Per-function complexity drill-downs: AdminLive.Workflows has 1 function >= 5 (workflow_cluster_role/1 at 6), SkillAPI has 1 (validate_skill_filename/1 at 5), SkillRegistry has 0. All complexity is spread thin across many functions — no single-function hotspots.

God modules with zero fan-in (AdminLive.Workflows, RSSCollector, LLM.Client) are safe refactoring targets. Config (centrality 23) and LLM (centrality 14) require careful change management.

---

## 6. Blast Radius (Top 3 Risk Modules)

### Config (change risk #1, score 1,275)

Depth 1 (26 direct dependents): Auth.TOTP, Config.Crypto, Config.Loader, Config.Seeder, Config.Setting, Dispatcher, Gateway, Gateway.Discord, Gateway.Telegram, Google.OAuth, Google.TokenManager, Identity, LLM, LLM.ProviderSeeder, RateLimiter, Repo, Resources.Migrator, Skills.GitHubSecurityReview, Skills.RSSCollector, Skills.Research, Skills.Shell, Skills.SkillAPI, Skills.WebAutomation, AdminLive.Config, GitHubWebhookController, TimeHelpers

Depth 2 (28 transitive): Dispatcher.AuthCommands, Dispatcher.AutomationCommands, Dispatcher.SkillCommands, LLM.UsageTracker, and 24 additional modules

Total blast radius: 54 modules affected (46% of the codebase).

Cascading hub risk: Gateway (fan-in 16), LLM (fan-in 14), and Repo (fan-in 19) are all depth-1 dependents of Config. A breaking change in Config cascades through three major hubs simultaneously.

### LLM (change risk #2, score 1,048)

Depth 1 + Depth 2: 27 modules affected. Includes all skill modules that use LLM completion, plus AdminLive views.

### Workflows (change risk #4, score 702)

Depth 1 + Depth 2: 13 modules affected. Well-encapsulated context — blast radius limited to executor, scheduler, and admin views.

---

## 7. Unprotected Hubs

**0 RED, 0 YELLOW.** All hub modules have adequate spec and doc coverage.

Session history: started with 2 RED (Skills.Helpers 0%, LLM.Provider 0%), then xref revealed 3 more (TimeHelpers 0%, TokenManager 43%, CircuitBreaker 56%). All 5 resolved through targeted spec additions across multiple fix rounds.

---

## 8. Coupling Analysis (Top 10 Project-Internal)

| Caller | Callee | Call Count | Distinct Functions |
|---|---|---|---|
| Dispatcher | Gateway | 31 | 1 |
| Workflows | Repo | 29 | 12 |
| AdminLive.Workflows | Workflows | 23 | 13 |
| Workflows | Workflow | 19 | 2 |
| Dispatcher.SkillCommands | Gateway | 18 | 1 |
| Dispatcher.AutomationCommands | Gateway | 16 | 1 |
| Dispatcher.AuthCommands | Gateway | 14 | 2 |
| Auth.TOTP | Config | 11 | 3 |
| AdminLive.Cluster | Cluster | 11 | 8 |
| Resources | Resource | 11 | 2 |

All coupling is by-design: dispatch-to-gateway routing (messaging pipeline), context-to-repo CRUD (Ecto pattern), LiveView-to-context delegation (Phoenix convention). The Dispatcher-to-Gateway split across 4 modules (31+18+16+14 = 79 calls) is the dispatch architecture — intentional and well-structured after the v0.3.9 consolidation.

---

## 9. Dead Code

5 of 765 (0.7%):

| Module | Function | Line | Status |
|---|---|---|---|
| Release | migrate/0 | 8 | Release command — invoked via bin/alex_claw eval |
| Release | seed_examples/0 | 16 | Release command — invoked via bin/alex_claw eval |
| Resources.Migrator | migrate_feeds/0 | 9 | One-time migration utility |
| WebAutomation | force_stop/0 | 111 | IEx debugging helper |
| WebAutomation | status/0 | 108 | IEx debugging helper |

0 genuinely unused functions. All 5 are invoked from release scripts or IEx sessions, not from application code paths.

---

## 10. Struct Lifecycle

| Struct | Fields | Users | Pattern-Match Modules |
|---|---|---|---|
| Message | 6 | 6 | Dispatcher + 3 command modules + 2 gateways |
| Auth.AuthContext | 7 | 2 | AuditLog, PolicyEngine |
| Auth.CapabilityToken | 3 | 1 | PolicyEngine |

Idiomatic Elixir pattern matching within the same application boundary. The compiler enforces struct shape at compile time — if a struct changes, mix compile catches every breakage instantly.

---

## 11. Semantic Duplicates

1 cluster at >= 90% similarity:

| Function A | Function B | Similarity |
|---|---|---|
| CoreComponents.flash_group/1 | CoreComponents.flash/1 | 97.7% |

HEEx component variants — flash_group renders a container of flash messages, flash renders a single one. Structural similarity from similar HTML markup, not duplicated logic.

---

## 12. Architecture Health

| Check | Status |
|---|---|
| Circular Dependencies | 2 cycles (xref-revealed, see below) |
| Behaviour Integrity | Consistent — 0 fractures |
| Orphan Specs | 0 |
| Dead Code | 5 functions (0 genuinely unused) |

### Circular Dependencies (xref-revealed)

**Cycle 1 (large, 15 modules):** Dispatcher -> Dispatcher.AuthCommands -> ... -> SkillRegistry -> Executor -> SkillAPI -> Gateway -> ... -> Dispatcher

This is the skill dispatch-and-execution cycle: Dispatcher routes commands to skills, skills call SkillAPI for side effects, SkillAPI uses SkillRegistry to resolve skills, Executor runs workflows that invoke skills. This is inherent to the plugin architecture — skills need to invoke other skills, and the dispatcher needs to know about skills. Breaking this cycle would require a fundamentally different architecture (event bus, message queue). Not a defect — it's the runtime dispatch loop.

**Cycle 2 (small, 2 modules):** LLM <-> LLM.UsageTracker

UsageTracker calls LLM.init_usage_table/0 on startup, and LLM calls UsageTracker.persist/1 on each API call. This is a tight init/tracking coupling. Could be broken by having Application.start initialize the ETS table instead, but the current design is simple and correct.

Neither cycle indicates a structural problem. Both are runtime dispatch patterns common in plugin-based OTP systems.

---

## 13. Runtime Health

Giulia daemon self-introspection (not AlexClaw container):

| Processes | Memory | Schedulers | Run Queue | Uptime | ETS Tables |
|---|---|---|---|---|---|
| 545 | 112.5 MB | 24 | 0 | 465s | 71 (5.1 MB) |

All nominal. Run queue 0, no scheduler pressure, no alerts.

---

## 14. Recommended Actions

All P0 and P1 items resolved. Only optional improvements remain.

### P2

**1. AdminLive.Workflows — organizational split (god module score 318, complexity 143, 32 functions)**

Zero fan-in makes this the safest refactoring target. Complexity spread thin (1 function >= 5). Split along functional boundaries: workflow form handling, step management, execution controls. Navigability improvement only.

**2. LLM/UsageTracker cycle — optional decoupling**

Move ETS table initialization from LLM.init_usage_table/0 to Application.start/2 to break the LLM <-> UsageTracker cycle. Low priority — the current design is simple and works correctly.

### P3

**1. Spec coverage from 60.7% toward 70%**

The remaining unspecced functions are OTP behaviour callbacks where @impl true provides the contract. Adding specs would be technically correct but boilerplate. Consider only if adopting Dialyzer for static analysis.

---

*Generated by [Giulia](https://github.com/thatsme/Giulia) v0.1.0.143 — D:/Development/GitHub/AlexClaw — 70 endpoints, 2026-03-24*
