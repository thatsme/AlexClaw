# AlexClaw — Architecture Analysis Report

> **Intelligence delivered by [Giulia](https://github.com/thatsme/Giulia)** — Local-first AI code intelligence for the BEAM.

Scanned 2026-09-20T07:56:16Z · merkle root `ecd4dd869b0f` · cache warm · 160 files

---

## Section 1: Executive Summary

| Metric | Value |
|---|---|
| Source files | 160 |
| Modules (index) | 160 |
| Functions | 1,751 |
| Types | 37 |
| Specs | 620 |
| Structs | 4 |
| Callbacks | 20 |
| Public functions | 716 |
| Private functions | 1,035 |
| Public ratio | 40.9% |
| Spec coverage | 620 specs / 716 public functions (86.6%) |
| Graph vertices | 2,019 |
| Graph edges | 2,618 |
| Connected components | 551 |
| Circular dependencies | **7** |
| Behaviour fractures | 0 |
| Orphan specs | 0 |
| Dead code | 0 of 1,751 functions — over 551 connected components |
| Graph edge parity | L2 UNAVAILABLE (endpoint 500) · L1=1,689 / L3=1,689 CALLS, delta=0 |

**Dead-code / components reconciliation.** Dead code reads 0 while the graph
carries 551 components over 2,019 vertices. These are not in tension: isolated
and zero-edge function vertices are held out of the dead-code list by the
classifier's exclusion categories — OTP callbacks, behaviour implementations,
framework entry points, and dynamic dispatch through `apply/3`, captures and
MFA tuples. This codebase is unusually dense in exactly those forms: 20
callbacks, 16 LiveViews whose `mount/3` and `handle_event/3` are never called
from project code, and a skill registry that resolves every skill by name at
runtime. The component fragmentation follows from that exclusion, not from an
absence of unused code. **0 dead code here is not a clean bill of health — it
is an unexamined surface**, and the honest statement is that static analysis
cannot see the skill dispatch path at all.

**Edge parity.** `verify_l2` returned HTTP 500, so the L2 figure is
unreconciled this run. `verify_l3` reports its own L1↔L3 comparison as
`match`, 1,689 CALLS edges each, delta 0, with every sampled bucket clean
(local 1,101, alias_resolved 450, direct 133, predicate_bang 82, and 5
capture/MFA edges). The agent-facing L3 store agrees with L1; the L2 leg is the
blind spot.

**Verdict.** Structurally healthy for its size — no behaviour fractures, no
orphan specs, 86.6% spec coverage on public functions, and a 40.9% public ratio
squarely in the healthy band. The single biggest gap is **7 dependency cycles**,
all of them context↔implementation pairs that will bite on any attempt to
extract a library or compile modules independently.

---

## Section 2: Heatmap Zones

169 modules scored (includes test-support modules). Red 1, Yellow 41, Green 127.

**Test-detection sanity check first**, per the scoring interaction: `has_test`
is true for 114 of 169 modules (67%). That is plausible for a project with
1,384 passing tests, so the 25-point test weight is not systematically
inflating scores. See the caveat under the assertion floor below.

### Red Zone (score >= 60)

| Module | Score | Complexity (module control-flow) | Centrality | Max Coupling | Tests? |
|---|---|---|---|---|---|
| Workflows.SkillRegistry | 69 | 221 | 15 | 36 | yes |

One module in the red, and it is the correct one: the registry is the ETS owner
for the skill catalogue, the AST gate for dynamic loading, and the resolution
point every dispatch path goes through.

### Yellow Zone (score 30-59) — 41 modules

| Module | Score | Module | Score |
|---|---|---|---|
| Workflows | 55 | Skills.SkillAPI | 36 |
| Skills.CodeGenerator | 48 | RAG.Chunker | 36 |
| Web.AdminLive.Chat | 48 | LLM | 36 |
| Web.AdminLive.Services | 46 | Web.Endpoint | 35 |
| Web.AdminLive.Workflows | 41 | Web.AdminLive.Forge | 35 |
| Dispatcher | 40 | Workflows.Executor | 34 |
| Config | 39 | Reasoning | 33 |
| Memory | 39 | Knowledge | 32 |
| Reasoning.Loop | 39 | Skills.Shell | 31 |
| Resources.ApiDiscovery | 37 | + 22 more at 30-31 | |

### Green Zone (score < 30)

127 modules. Notable: every Ecto schema, every plug, and the whole
`Skills.*` fetch family sit here — small, tested, low fan-in.

### Test Coverage Gap Analysis

**55 modules have no test file** by path convention. Grouped by reason:

| Group | Count | Actionable? | Notes |
|---|---|---|---|
| Ecto schemas (changeset-only) | 11 | By design | changeset/2 is exercised through the context tests that insert records |
| LiveView modules | 9 | Partly | Covered collectively by smoke_test.exs and per-page tests; individual mounts are not unit-tested |
| Supervisors and starters | 6 | By design | Reasoning.Supervisor, SkillSupervisor, CircuitBreakerSupervisor, DiscordStarter — behaviour is the supervision tree, asserted by boot |
| Thin facades / delegators | 7 | Low value | Gateway, Repo, Scheduler, Skill, Message |
| Controllers with a test elsewhere | 5 | By design | Named *_controller_test.exs under a different path |
| Genuinely untested, actionable | 17 | **Yes** | See quick wins |

**Quick wins** — standard interface, simple setup, no daemon or external
service required: `Knowledge.EmbedThrottle` (6 public functions, a GenServer
with a clean acquire/release API), `UpdateChecker` (4 functions, pure HTTP),
`RAG.QueryRewriter` (ETS cache plus one LLM call, already mockable through the
`LLM.Behaviour` seam), `Resources.Migrator` (one function, one DB read),
`Config.EncryptExisting` (one function, idempotent).

**Nominal coverage — and a detector caveat.** The assertion floor asks for the
mapped test file to be opened and its assertions counted. Applying the
documented mapping (`lib/foo.ex` → `test/foo_test.exs`) to the 114 modules
flagged `has_test = true`, **25 of them have no file at that path at all** —
for example `MCP.Server` → `test/alex_claw/mcp/server_test.exs` (absent) and
`Skills.Research` → `test/alex_claw/skills/research_test.exs` (absent).

Spot-checking those two, both **are** genuinely tested, by
`test/alex_claw/mcp/server_policy_test.exs` and
`test/alex_claw/skills/step_fields_test.exs` respectively. So the flag is
substantively correct while its provenance does not match the documented
path-convention mapping — Giulia is resolving these more cleverly than
`suggest_test_file` is described as doing. **Consequence for this report: the
assertion floor cannot be applied mechanically**, because the file it would
open is not the file that does the testing. Two modules were confirmed below
the floor on their own mapped files — `AlexClaw` (1 assertion, 9 lines) and
`Web.DatabaseController` (1 assertion, 17 lines) — and both should be read as
nominal coverage carrying a 25-point credit they have not earned.

*This mapping discrepancy is a finding about the tooling, not the codebase, and
is listed again in Section 16.*

---

## Section 3: Top 5 Hubs

| Module | In-Degree | Out-Degree | Risk Profile |
|---|---|---|---|
| Config | 43 | 3 | Pure hub — stable interface, everything reads settings through it |
| Repo | 33 | 0 | Pure sink — the Ecto repo, depended on by every context, depends on nothing |
| Skill | 23 | 0 | Pure sink — the behaviour every skill implements; a contract, not code |
| LLM | 21 | 4 | Pure hub — the provider-routing facade |
| Memory | 16 | 7 | Pure hub — the pgvector read path |

Immediately below the top five: Workflows.SkillRegistry (15 in, 28 out) and
Workflows (15 in, 8 out). SkillRegistry is the project's only genuine
bidirectional hub — a critical junction with blast radius in both directions —
and it is worth reading alongside this table even though its fan-in does not
quite reach the top five.

Phoenix.LiveView and GenServer carry comparable degree but are framework
modules, excluded as external.

---

## Section 4: Change Risk (Top 10)

| Rank | Module | Score | Key Driver |
|---|---|---|---|
| 1 | Workflows.SkillRegistry | 5,899 | All four dimensions — 99 functions, complexity 221, centrality 15, coupling 36 |
| 2 | Config | 3,015 | Centrality — 46 dependents against only 18 functions |
| 3 | Workflows | 2,550 | Function count — 42 public context functions |
| 4 | Skills.SkillAPI | 1,431 | Centrality plus breadth — 42 functions, 14 dependents |
| 5 | Workflows.Executor | 1,340 | Complexity and coupling — the step walker |
| 6 | Web.AdminLive.Workflows | 1,317 | Function count — 64 functions in one LiveView |
| 7 | Memory | 1,251 | Centrality — the pgvector read path |
| 8 | Dispatcher | 1,072 | Fan-out — 34 functions across 22 dependencies |
| 9 | LLM | 977 | Centrality — provider routing facade |
| 10 | Reasoning.Loop | 976 | Complexity — 228, the highest in the project |

The formula is multiplicative, which is why SkillRegistry at rank 1 scores
almost double rank 2: it is the only module elevated on every axis at once.

---

## Section 5: God Modules

20 modules flagged. Top 10:

| Module | Functions | Complexity (module control-flow) | Score |
|---|---|---|---|
| Workflows.SkillRegistry | 99 | 221 | 586 |
| Reasoning.Loop | 91 | 228 | 550 |
| Web.AdminLive.Workflows | 64 | 187 | 447 |
| Skills.SkillAPI | 42 | 123 | 303 |
| Web.AdminLive.Chat | 24 | 126 | 279 |
| Dispatcher | 34 | 118 | 279 |
| Workflows.Executor | 42 | 89 | 244 |
| Config | 18 | 41 | 229 |
| Web.AdminLive.Services | 18 | 93 | 207 |
| Workflows | 42 | 60 | 207 |

**Commentary.** `Workflows.SkillRegistry` is a genuine split candidate — the
AST gate, the staging/promotion lifecycle and the ETS catalogue are three
responsibilities in one module. `Reasoning.Loop` is a `gen_statem`; its
complexity is the state machine and is by design. The three LiveViews
(`AdminLive.Workflows`, `.Chat`, `.Services`) are high complexity with **zero
fan-in** — nothing depends on them, so they are refactoring opportunities at
low risk, not hazards.

**Per-function drill-down.** Complexity is spread thin rather than
concentrated in all three top modules — no function in the project scores above
7 on cognitive complexity:

| Module | Function | Arity | Cognitive complexity |
|---|---|---|---|
| Workflows.SkillRegistry | validate_skill_filename | 1 | 5 |
| Reasoning.Loop | validate_plan | 2 | 6 |
| Reasoning.Loop | handle_phase_result | 3 | 5 |
| Web.AdminLive.Workflows | resource_endpoints | 1 | 7 |
| Web.AdminLive.Workflows | workflow_cluster_role | 1 | 6 |

That is the most reassuring number in the report: a 221-complexity module whose
worst function scores 5 is a module with many small functions, not a module
with a monster in it. The module-level figures are breadth, not depth.

---

## Section 6: Blast Radius (Top 3 Risk Modules)

### Workflows.SkillRegistry (change_risk rank #1)

Depth 1 + 2 (dependents, 30 modules): Application, ContentSanitizer,
Dispatcher, Dispatcher.AuthCommands, Dispatcher.SkillCommands, MCP.Server,
MCP.ToolSchema, Reasoning.SkillExecutor, Skills.CodeGenerator, Skills.SkillAPI,
Workflows.Executor, Web.AdminLive.Skills, Web.AdminLive.Forge, and 17 more.

Upstream (52 modules it depends on): every skill module, Repo, Skills.Helpers.

Total blast radius: **30 modules downstream, 52 upstream**
Functions with outgoing call edges: **49**

**Cascading hub risk: none downstream.** No Top 5 Hub appears among the 30
dependents. All five — Config, Repo, Skill, LLM, Memory — sit *upstream*, which
is the reassuring direction: SkillRegistry depends on the hubs rather than the
hubs depending on it. Its blast radius is wide but terminal.

### Config (change_risk rank #2)

Depth 1 + 2 (dependents, 75 modules): effectively the entire application —
Gateway.Discord, Reasoning.Loop, Web.Plugs.McpAuth, Config.Loader, Dispatcher,
every skill, Knowledge, Memory, and 65 more.

Upstream (4): Config.Crypto, Config.Setting, Repo, Web.Endpoint.

Total blast radius: **75 modules — 44% of the codebase**
Functions with outgoing call edges: **17**

**Cascading hub risk: two.** LLM and Memory are both Top 5 Hubs and both sit
downstream of Config — changing Config cascades through LLM to its 21
dependents and through Memory to its 16. This is the one place in the project
where a hub feeds another hub.

The shape is the classic pure hub: 75 dependents, 4 dependencies, 17 function
edges. A signature change to `get/2` or `set/3` touches almost everything,
which is precisely why the 0.3.26 work added `sensitive?/1` beside them rather
than changing either.

### Workflows (change_risk rank #3)

Depth 1 + 2 (dependents, 27 modules): Dispatcher, Dispatcher.AuthCommands,
MCP.ResourceProvider, MCP.Server, MCP.ToolSchema, Release, Skills.SkillAPI,
Workflows.Executor, Workflows.Registry, Workflows.SchedulerSync, and 17 more.

Upstream (8): Repo and the seven schema modules.

Total blast radius: **27 modules**
Functions with outgoing call edges: **94** — the highest of the three,
reflecting a wide context API rather than deep call chains. No Top 5 Hub is
downstream; only Repo sits upstream.

---

## Section 7: Unprotected Hubs

| Module | In-Degree | Spec Coverage | Doc Coverage | Severity |
|---|---|---|---|---|
| Reasoning.Supervisor | 3 | 0% | 0% | red |
| Knowledge.EmbedThrottle | 3 | 33% | 0% | red |
| Cluster.Manager | 3 | 40% | 20% | red |
| Workflows.Registry | 6 | 75% | 75% | yellow |
| SkillSupervisor | 6 | 67% | 33% | yellow |
| Gateway.Telegram | 6 | 56% | 44% | yellow |
| Web.AdminLive.Workflows | 3 | 67% | 0% | yellow |
| UpdateChecker | 3 | 50% | 25% | yellow |
| LLM.UsageTracker | 3 | 50% | 25% | yellow |
| MCP.Server | 3 | 75% | 0% | yellow |
| Auth.SkillRateLimiter | 3 | 50% | 25% | yellow |
| Web.AdminLive.LLM | 3 | 67% | 0% | yellow |

**Key insight.** 620 specs exist project-wide, concentrated in the skill and
context modules where the public API is stable. The gap is in OTP plumbing:
the three red hubs are all supervised processes, where the contract that
matters is the process lifecycle rather than the function signature — which is
why they were never specced, and also why a reader cannot tell from the source
what `EmbedThrottle.acquire/0` blocks on.

---

## Section 8: Coupling Analysis (Top 10 Pairs)

Project-internal pairs only; stdlib coupling excluded.

| Caller | Callee | Call Count | Distinct Functions |
|---|---|---|---|
| Dispatcher | Gateway | 59 | 1 |
| Workflows.SkillRegistry | Skills.Helpers | 36 | 4 |
| Web.AdminLive.Workflows | Workflows | 31 | 12 |
| Skills.SkillAPI | Auth.PolicyEngine | 24 | 1 |
| Workflows.Executor | Workflows | 21 | 8 |
| Dispatcher.SkillCommands | Workflows.SkillRegistry | 18 | 6 |
| Reasoning.Loop | Reasoning | 17 | 11 |
| Web.AdminLive.Skills | Workflows.SkillRegistry | 15 | 7 |
| Skills.SkillAPI | Workflows.SkillRegistry | 13 | 4 |
| Config.Loader | Config | 11 | 3 |

**By design.** `Dispatcher → Gateway` at 59 calls across a single function is
every command reply routing through one facade — high count, one contract, no
coupling problem. `Reasoning.Loop → Reasoning` (17 calls, 11 functions) is the
`gen_statem` writing to its own persistence context, the thin-process/pure-state
split the conventions recommend. `Skills.SkillAPI → Auth.PolicyEngine` at 24
calls on one function is every permission check going through one gate, which
is the security property the architecture wants.

---

## Section 9: Dead Code

**0 total flagged dead** — actionable 0 (genuine + uncategorized), irreducible 0
(library_public_api + test_only + template_pending). Of 1,751 total functions
(0.0%) — **over 551 connected components**.

See the Section 1 reconciliation: the zero is a product of the classifier's
exclusion categories meeting a codebase built on runtime dispatch. Every skill
is resolved by string name through the registry; every LiveView callback is
invoked by Phoenix; every `handle_info/2` is invoked by OTP. None of these
edges exist statically, which is what produces 551 components, and the same
exclusions that create the components suppress the dead-code list. The correct
reading is "static analysis found nothing it is allowed to flag", not "there is
no unused code".

---

## Section 10: External Tool Findings

**Skipped — project never enriched.** No `dead_code` entry carries an
`enrichments` key (the list is empty, so there is no entry to carry one), and no
`:enrichments_summary` is present. External-tool enrichments are not configured
for this project: CI runs Credo but does not push results to
`POST /api/index/enrichment`.

Worth noting because the gap is narrow: the project's CI already runs
`mix credo --strict` and currently reports zero issues, so ingesting it would
cost one pipeline step and would let Section 10 corroborate Section 15 rather
than leaving Giulia's own AST checks unwitnessed.

---

## Section 11: Struct Lifecycle

| Struct | Defining Module | User Count | Logic Leaks | Leak Count |
|---|---|---|---|---|
| Message | AlexClaw.Message | 6 | yes | 6 |
| Auth.AuthContext | AlexClaw.Auth.AuthContext | 2 | yes | 2 |
| Auth.CapabilityToken | AlexClaw.Auth.CapabilityToken | 1 | yes | 1 |
| State | Reasoning.Loop.State | 1 | yes | 1 |

`%Message{}` is matched in Dispatcher, its three command submodules, and both
gateways. That is the coupling metric doing its job — six modules would need
updating if the shape changed — and in Elixir the compiler reports every one of
them the moment it does. Pattern matching a message struct in a dispatcher is
the idiomatic shape for this problem, not a defect. The same applies to
`AuthContext` across AuditLog and PolicyEngine.

No struct has zero users, so none is dead. None crosses a library boundary
where `@opaque` would be worth the ceremony.

---

## Section 12: Semantic Duplicates

**1 cluster found at >= 90% similarity.**

| Cluster | Similarity | Members |
|---|---|---|
| 1 | 95.1% | RAG.Chunker.should_chunk?/1, RAG.Chunker.chunk/2 |

Both members are in the same module and neither delegates to the other — this
is not a `defdelegate` artifact. `should_chunk?/1` tests the same size
threshold that `chunk/2` then acts on, so the two share their guard shape. That
is a 4-line predicate next to the function it guards, which is the correct
structure; the embedding sees structural similarity, not duplicated logic.
No action.

---

## Section 13: Architecture Health

| Check | Status |
|---|---|
| Circular dependencies | **7 cycles found** |
| Behaviour integrity | Consistent — 0 fractures |
| Orphan specs | 0 |
| Dead code | 0 functions (0 genuinely unused) — over 551 connected components |
| Graph edge parity (L2 vs L3) | **L2 UNAVAILABLE (endpoint returned HTTP 500)** — L1=1,689, L3=1,689, delta=0 |

### The 7 cycles (P0)

| # | Chain |
|---|---|
| 1 | ContentSanitizer → Skills.SkillAPI → Workflows.Executor → Workflows.SkillRegistry |
| 2 | Skills.CircuitBreaker → Skills.CircuitBreakerLifecycle → Skills.CircuitBreakerSupervisor |
| 3 | Workflows → Workflows.Registry |
| 4 | Reasoning.Session → Reasoning.Step |
| 5 | LLM → LLM.UsageTracker |
| 6 | Resources → Resources.ApiDiscovery |
| 7 | Reasoning → Reasoning.Loop |

Six of the seven are the same shape: a context module and the process or schema
that calls back into it (`LLM`/`UsageTracker`, `Reasoning`/`Loop`,
`Workflows`/`Registry`, `Resources`/`ApiDiscovery`,
`Reasoning.Session`/`Step`). In Elixir these compile and run without complaint —
they are cycles in the dependency graph, not in module compilation. They matter
for a specific reason: no one of these pairs can be extracted, tested in
isolation, or moved to another application without the other coming with it.

Cycle 1 is the one worth attention — a four-module cycle spanning sanitisation,
the permission API, the executor and the registry. That is the security-relevant
path, and it means those four modules form a single unit for reasoning purposes.

---

## Section 14: Runtime Health

**Data unavailable.** `alexclaw-prod` is not running — it was stopped at
2026-09-19T09:17:05Z (a `docker compose down` before a test run; exit 137 is the
stop-grace SIGKILL, `OOMKilled=false`). Giulia's `/api/runtime/pulse` returns
the daemon's own node (`worker@giulia-worker`), not AlexClaw's, and no AlexClaw
node is connected to the monitor.

No fused observation sessions exist for this project, so the static/runtime
correlation view is also unavailable.

**One runtime-adjacent finding stands without the daemon**: the container's
BEAM does not complete shutdown within Docker's 10-second stop grace, so every
`make down` terminates it with SIGKILL. No `stop_grace_period` is set in either
compose file. In-flight workflow steps die mid-execution and `terminate/2` never
runs.

---

## Section 15: Convention Violations

> Convention scan: **0 errors, 50 warnings, 21 info** across the project.
> Error-tier rules checked: try_rescue_flow_control, silent_rescue,
> runtime_atom_creation.

### 15a. Errors

**None.** No `try_rescue_flow_control`, no `silent_rescue`, no
`runtime_atom_creation` anywhere in the project. For a codebase that compiles
LLM-generated modules at runtime, zero runtime atom creation is the single most
important of those three, and it holds.

### 15b. Warnings and info

| Rule | Count | Severity | Category |
|---|---|---|---|
| missing_spec | 28 | warning | documentation |
| process_dictionary | 21 | warning | otp |
| single_value_pipe | 20 | info | pipes |
| missing_moduledoc | 1 | warning | documentation |
| missing_enforce_keys | 1 | info | structs |

**`process_dictionary` (21) is the one to look at.** The uses are deliberate —
the capability token and auth chain depth are put in the process dictionary by
`SafeExecutor` and read by `SkillAPI`, which is how a skill running in a spawned
process inherits its authorisation without threading it through every call. That
is a defensible design for exactly this problem, but it is 21 sites of implicit
state on the security path, and it is invisible to the type system and to every
reader who has not been told.

`missing_spec` (28) concentrates in the LiveViews and supervisors, matching the
unprotected-hub finding in Section 7.

---

## Section 15b: Process Architecture

**Supervision summary.** One root supervisor, `AlexClaw.Supervisor`, one tier,
`one_for_one`, 22 unconditional children plus 2 conditional
(`Workflows.SchedulerSync` and `Gateway.DiscordStarter`, both gated on
`:start_background_workers`). No supervisor reports `children_unresolved`.

> Checks run: 8. Findings: **3 errors, 16 warnings, 0 info** (19 total).

### Errors — every one listed

| Check | Module | Line | Detail |
|---|---|---|---|
| blocking_init | LLM.UsageTracker | 66 | Repo.all called from init/1 |
| blocking_init | LLM.UsageTracker | 103 | AlexClaw.Repo.one called from init/1 |
| blocking_init | Workflows.SkillRegistry | 346 | Repo.all called from init/1 |

All three serialise boot on a database round-trip inside `init/1`. Both modules
are supervision children of the root supervisor, so a slow or unavailable
database delays every sibling started after them — and `SkillRegistry` is
child 7 of 22, ahead of the gateways, the MCP server and the endpoint. Under a
restart storm this is the shape that turns one slow query into a
restart-intensity tree death. The fix is the one the message names:
`{:ok, state, {:continue, :load}}` and do the query in `handle_continue/2`.

**No `cross_process_call_cycle` at any confidence** — there is no GenServer
deadlock ring in this project. That is a real property, not an empty subgraph:
the codebase has 12 supervised processes that do call each other, so the check
had something to examine.

### Warnings

| Check | Count | Top offenders |
|---|---|---|
| missing_catch_all_handle_info | 12 | Cluster.Manager, Config.Loader, Gateway.Telegram, LLM.UsageTracker, Workflows.Registry |
| blocking_init | 4 | Config.Loader (File.mkdir_p! at line 27), Google.TokenManager, RateLimiter.Server |

`missing_catch_all_handle_info` across 12 processes means an unexpected message
— a late `:DOWN`, a stray PubSub broadcast, a reply to a timed-out call — will
crash the process rather than be ignored. For `Cluster.Manager`, which monitors
nodes, and `Workflows.Registry`, which monitors every running workflow, that is
a live risk rather than a theoretical one.

`singleton_bottleneck`: no findings. Note that with no Collector data available
for this project, any such finding would have read `runtime: unavailable` —
unconfirmed, not clean.

---

## Section 16: Recommended Actions

### P0

**1. Break the four-module security cycle.** ContentSanitizer →
Skills.SkillAPI → Workflows.Executor → Workflows.SkillRegistry. These four
cannot be reasoned about, tested, or extracted independently, and they are the
path every skill side effect and every sanitisation decision travels. Breaking
the SkillAPI → Executor edge is the smallest cut: the executor's need for
SkillAPI is the capability token, which could be passed rather than fetched.

**2. Move the three blocking `Repo` calls out of `init/1`.**
`LLM.UsageTracker:66`, `LLM.UsageTracker:103`, `Workflows.SkillRegistry:346`.
`SkillRegistry` is child 7 of 22 — every process after it waits on that query.
Convert to `{:ok, state, {:continue, :load}}`. Expected impact: boot no longer
serialises on the database, and a restart storm cannot compound into tree death.

**3. Restore L2 edge-parity verification.** `verify_l2` returns HTTP 500, so
one leg of the parity check is unreconciled. L1↔L3 matched exactly (1,689 =
1,689), so nothing is known to be wrong — but the check that would tell us is
down, and given the CALLS-downgrade history this should not sit broken.

### P1

Sorted by `in_degree * (1 - coverage_ratio)`:

**4. Spec and document `Cluster.Manager`** (in-degree 3, 40% spec, 20% doc) and
**`Knowledge.EmbedThrottle`** (in-degree 3, 33% spec, 0% doc) — both red
unprotected hubs, both supervised processes whose contract is a lifecycle no
reader can infer from the source. `EmbedThrottle` is also a test quick win.

**5. `Reasoning.Supervisor`: 0% spec, 0% doc, no test, 3 dependents.** The
highest-scoring unprotected hub in the project on the fan-in-weighted ordering.

**6. Add catch-all `handle_info/2` to `Cluster.Manager` and
`Workflows.Registry`.** Both monitor external things and will receive messages
they do not expect; both currently crash on them.

**7. Audit the 21 `process_dictionary` sites on the auth path.** The design is
defensible — implicit capability propagation into spawned skill processes — but
it is the security mechanism's storage and it is invisible. It needs a
`@moduledoc` stating the contract, at minimum.

**8. Two nominal-coverage modules** — `AlexClaw` (1 assertion) and
`Web.DatabaseController` (1 assertion) — are being credited 25 heatmap points
they have not earned.

### P2 / P3 (3 combined)

**9. Split `Workflows.SkillRegistry`** (P2). 99 functions, complexity 221, the
only red-zone module and rank 1 on change risk. Three responsibilities live
there: the AST gate, the staging and promotion lifecycle, and the ETS catalogue.
Extracting the AST gate alone would move roughly 80 complexity points out of the
highest-blast-radius module in the project. Note its worst function scores only
5 on cognitive complexity — this is a breadth problem, so splitting is low-risk.

**10. Ingest Credo output into Giulia** (P3). CI already runs `mix credo
--strict` at zero issues; pushing results to `POST /api/index/enrichment` would
turn Section 10 from skipped into corroboration.

**11. Set `stop_grace_period` in both compose files** (P3). The BEAM is
SIGKILLed on every stop, so in-flight workflow steps die mid-execution and
`terminate/2` never runs.

---

*Intelligence delivered by [Giulia](https://github.com/thatsme/Giulia) v0.3.8.164 — /projects/AlexClaw — 2026-09-20*
