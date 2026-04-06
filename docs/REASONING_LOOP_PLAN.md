# Reasoning Loop Engine — Implementation Plan

## Overview

An autonomous reasoning loop for AlexClaw that can plan, execute, evaluate, and iterate
on tasks using local LLM models only, with full user intervention capability and
comprehensive audit trail.

## Core Loop

```
User Goal
    ↓
[Memory/Knowledge Search] → Prior context
    ↓
PLANNING (LLM) → Structured plan with steps
    ↓
┌─→ EXECUTING → Invoke whitelisted skill
│       ↓
│   EVALUATING (LLM) → Rubric-scored assessment
│       ↓
│   DECIDING (LLM) → continue | adjust | ask_user | done | stuck
│       ↓
│   ┌── continue ──→ next step ──┐
│   ├── adjust ────→ re-plan ────┤
│   ├── ask_user ──→ pause, wait ┤
│   ├── done ──────→ deliver ────┤
│   └── stuck ─────→ terminate ──┘
│                                │
└────────────────────────────────┘
```

## Design Decisions

### Working Memory Model
Single `working_memory` string threaded through ALL 4 prompts. Each LLM response
includes an updated `working_memory` field. This prevents context fragmentation
across phases. The working memory is the loop's "train of thought."

### OTP Architecture
- **GenServer** (not recursive function) — must be pauseable and steerable mid-flight
- **DynamicSupervisor** — transient restart, clean lifecycle per session
- **Task-based LLM calls** — non-blocking, GenServer stays responsive to intervention
- **PubSub** — real-time UI updates on every phase transition

### Security
- **Forced `:local` tier** — hardcoded, not configurable
- **Skill whitelist** — frozen at session start from config
- **No dynamic skill creation** — only `SkillRegistry.resolve`, never load/create
- **Capability tokens** — minted per skill invocation, scoped permissions
- **ContentSanitizer** — applied to all external skill outputs
- **Chain depth** — reset to 0 per skill call, existing max 3 for nested

### Stuck Detection
- `consecutive_failures` resets to 0 on any success
- Duplicate detection: `{skill_name, sha256(input)}` — last 3 pairs tracked
- Same pair 3 times → stuck
- Different inputs to same skill is NOT stuck

### Goal Satisfaction
- Decision prompt returns `confidence` (0.0–1.0)
- Config threshold `reasoning.done_confidence_threshold` (default 0.7)
- Below threshold: treat "done" as "continue", annotate working memory

### Steer UX (Two Modes)
1. **Free-text guidance** — injected into working_memory with `[USER GUIDANCE]` prefix
2. **Step override** — user forces next skill+input, bypasses decision phase, recorded as `phase: "user_override"`

### Sub-agent Protocol
- Out of scope for v1 (local models too weak for nested sessions)
- `parent_session_id` nullable FK added to schema for future use

### Result Delivery
- Always: store to Memory (`kind: :reasoning, source: "reasoning_loop"`)
- Optional: Telegram/Discord notify via `delivery_config`
- Config: `reasoning.default_delivery` defaults to `["memory"]`

### Memory Integration
- Before planning: `Memory.search(goal, limit: 5)` + `Knowledge.search(goal, limit: 3)`
- On completion: store result + working memory snapshot to Memory

## Database Schema

### reasoning_sessions
| Column | Type | Notes |
|--------|------|-------|
| id | bigserial | PK |
| goal | text, NOT NULL | Original user goal |
| status | string, NOT NULL | planning/executing/paused/completed/failed/aborted/stuck |
| plan | map, default %{} | LLM-generated plan (list of steps) |
| working_memory | text | Rolling context threaded through all prompts |
| config | map, default %{} | Frozen config snapshot at session start |
| delivery_config | map, default %{} | Delivery channels on completion |
| result | text | Final answer/summary |
| error | text | Error description if failed/stuck |
| confidence | float | Final goal satisfaction confidence |
| iteration_count | integer, default 0 | Loop iterations completed |
| total_llm_calls | integer, default 0 | LLM call counter |
| parent_session_id | references(self), nullable | For future sub-agent support |
| started_at | utc_datetime | |
| completed_at | utc_datetime, nullable | |
| timestamps | | inserted_at, updated_at |

### reasoning_steps
| Column | Type | Notes |
|--------|------|-------|
| id | bigserial | PK |
| session_id | references(reasoning_sessions) | on_delete: delete_all |
| iteration | integer, NOT NULL | 1-based loop iteration |
| phase | string, NOT NULL | plan/execute/evaluate/decide/user_override |
| skill_name | string, nullable | Skill invoked (execute/user_override phases) |
| llm_prompt | text | Prompt sent to LLM |
| llm_response | text | Raw LLM response |
| skill_input | map, default %{} | Args passed to skill |
| skill_output | text | Skill result (sanitized) |
| decision | string, nullable | continue/adjust/ask_user/done/stuck |
| confidence | float, nullable | Goal satisfaction confidence |
| rubric_scores | map, nullable | {relevance, completeness, usability, goal_progress} |
| user_guidance | text, nullable | Injected steering text |
| working_memory_snapshot | text | Working memory state after this step |
| duration_ms | integer | Wall-clock time |
| error | text, nullable | |
| timestamps | | |

## Configuration Keys

| Key | Default | Type | Description |
|-----|---------|------|-------------|
| reasoning.enabled | true | boolean | Feature flag |
| reasoning.max_iterations | 15 | integer | Max loop iterations |
| reasoning.max_llm_calls | 60 | integer | Max LLM calls per session |
| reasoning.time_budget_seconds | 900 | integer | Max wall-clock time (15 min) |
| reasoning.skill_whitelist | ["web_search", "web_fetch", ...] | json | Allowed skills |
| reasoning.stuck_threshold | 3 | integer | Consecutive failures before stuck |
| reasoning.step_timeout_seconds | 120 | integer | Per-skill execution timeout |
| reasoning.max_plan_steps | 8 | integer | Max steps in a plan |
| reasoning.done_confidence_threshold | 0.7 | float | Min confidence to accept "done" |
| reasoning.default_delivery | ["memory"] | json | Delivery channels |
| prompts.reasoning.planning | (template) | string | Planning prompt template |
| prompts.reasoning.execution | (template) | string | Execution prompt template |
| prompts.reasoning.evaluation | (template) | string | Evaluation prompt template |
| prompts.reasoning.decision | (template) | string | Decision prompt template |

## Evaluation Rubric

Each criterion scored 1–5 by the LLM:
- **relevance**: did the output address the step goal?
- **completeness**: is the output sufficient or partial?
- **usability**: can the next step use this output?
- **goal_progress**: did this move closer to the overall goal?

Quality: "good" if avg >= 3.5, "partial" if avg >= 2, "failed" otherwise

## Intervention Protocol

| Action | Mechanism | Effect |
|--------|-----------|--------|
| Pause | GenServer cast | Completes current task, then halts. Status → paused |
| Resume | GenServer cast | Continues from where it paused |
| Steer (text) | GenServer cast | Injected into working_memory, consumed by next decision |
| Step override | GenServer cast | Forces specific skill+input, bypasses decision |
| Abort | GenServer cast | Kills running task, terminates, status → aborted |
| Add context | GenServer cast | Appended to working_memory, persists across iterations |

## Safety Mechanisms

1. Max iterations (configurable, default 15)
2. Time budget proportional to plan step count (~300s/step + 120s buffer)
3. LLM call budget (configurable, default 60)
4. Stuck detection: 3 consecutive failures OR 3 duplicate {skill, input_hash}
5. Confidence threshold for "done" declarations (default 0.7)
6. Per-skill timeout via SafeExecutor (configurable, default 120s)
7. Orphaned session cleanup: terminate callback, boot sweep, LiveView mount check
8. Deterministic plan validation: reject steps with missing/non-whitelisted skills
9. Deterministic decision pre-filter: skip LLM for obvious cases (all done, stuck, continue)
10. Adjust oscillation guard: 3+ adjusts at done-level confidence → forced summary
11. LLM tier configurable (default: local)

## Known Limitations

### Output quality is model-dependent
The reasoning loop is an orchestration engine, not an intelligence engine. Output quality
is bounded by the configured LLM's ability to:
- Follow structured JSON output schemas consistently
- Compress and reconstruct context from the working memory string
- Make sound evaluation and planning judgments

Local models (7B-14B) produce functional but often imprecise results. They hallucinate
details when source material is thin, vary JSON key names across responses, and struggle
with multi-step context tracking. Routing to a stronger tier (light/medium/heavy) via
`reasoning.llm_tier` config significantly improves output quality at the cost of
privacy and API spend.

### JSON schema drift with local models
Local models do not reliably follow the exact JSON schema specified in prompts. The parser
includes extensive normalization (key aliases, extraction from malformed responses, trailing
comma removal, markdown fence stripping) but novel deviations may still cause parse failures.
The stuck threshold (default 3) catches repeated failures, but single-iteration data loss
is possible when a parse fails and the loop skips to the decision phase.

### Evaluation rubric is LLM-judged
The evaluation phase asks the LLM to score its own output on a 1-5 rubric. With local models
this self-assessment is unreliable — the model tends to rate its own output favorably. The
deterministic pre-filter mitigates this by handling obvious cases (all steps done, failures
at threshold) without consulting the LLM, but ambiguous cases still rely on model judgment.

### No parallel skill execution
Skills execute sequentially, one per iteration. A plan with 8 steps runs 8 serial cycles.
Independent steps (e.g., two web searches on different topics) could theoretically run in
parallel but the architecture does not currently support this.

### Working memory degradation
The working memory string grows with each phase. While compression runs every 3 iterations,
long sessions (10+ iterations) accumulate stale context that can confuse the model. The
compression pass itself depends on the LLM's ability to distinguish essential facts from noise.

### Time budget is an estimate
The proportional time budget (~300s per step) is based on observed local model performance.
Actual execution time varies with model size, hardware, network latency for web skills,
and content volume. Complex web fetches or large LLM transform inputs can exceed the estimate.

## Implementation Phases

### Phase 1: Database & Schemas
- Migration: reasoning_sessions + reasoning_steps
- Ecto schemas: Session, Step
- Context module: AlexClaw.Reasoning (CRUD)

### Phase 2: Prompt Engineering & Parsing
- AlexClaw.Reasoning.Prompts — builds 4 prompt templates with working_memory threading
- AlexClaw.Reasoning.PromptParser — defensive JSON extraction for local model output

### Phase 3: Skill Execution Wrapper
- AlexClaw.Reasoning.SkillExecutor — whitelist → resolve → token → execute → sanitize

### Phase 4: Core Loop
- AlexClaw.Reasoning.Loop (GenServer) — state machine, task-based LLM, PubSub, persistence
- AlexClaw.Reasoning.Supervisor (DynamicSupervisor)
- Wire into application.ex

### Phase 5: Configuration
- Add reasoning.* and prompts.reasoning.* to config seeder

### Phase 6: LiveView Transformation
- Dual-mode chat page (Chat / Reasoning toggle)
- Reasoning UI: goal, plan, timeline, intervention bar, result panel

### Phase 7: Tests
- PromptParser, Prompts, Loop lifecycle, Context CRUD
