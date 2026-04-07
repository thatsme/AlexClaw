# Reasoning Loop

The reasoning loop is an **autonomous agent cycle** that decomposes goals into plans, executes skills, evaluates results, and iterates until the goal is met. Unlike the [Workflow Engine](workflow-engine.md) which runs pre-defined step graphs, the reasoning loop builds and adapts its plan at runtime.

## Core Cycle

```
User Goal
    ↓
Prior Knowledge (Memory + Knowledge search)
    ↓
PLANNING ──→ LLM produces step plan
    ↓
┌─→ EXECUTE ──→ Invoke whitelisted skill
│       ↓
│   EVALUATE ──→ LLM scores result (rubric 1-5)
│       ↓
│   DECIDE ──→ continue | adjust | ask_user | done | stuck
│       ↓
│   ┌── continue ──→ next step ──┐
│   ├── adjust ────→ new plan ───┤
│   ├── ask_user ──→ pause ──────┤
│   ├── done ──────→ deliver ────┤
│   └── stuck ─────→ terminate ──┘
│                                │
└────────────────────────────────┘
```

## How It Works

The loop runs as a GenServer under a DynamicSupervisor. LLM calls run as Tasks so the GenServer stays responsive to user intervention (pause, abort, steer) during slow model inference.

**Planning** — The LLM receives the goal, available whitelisted skills with descriptions, and prior knowledge from Memory/Knowledge semantic search. It returns a JSON plan with ordered steps.

**Execution** — For each step, the LLM prepares concrete skill input, then the skill runs through the standard security stack: whitelist check, SkillRegistry resolve, capability token mint, SafeExecutor, CircuitBreaker, ContentSanitizer.

**Evaluation** — The LLM scores the skill output on four criteria (relevance, completeness, usability, goal progress) each 1-5. Quality is derived: good (avg >= 3.5), partial (>= 2.0), failed.

**Decision** — A mix of deterministic logic and LLM judgment. Obvious cases are handled without an LLM call:

| Condition | Decision | LLM call? |
|---|---|---|
| All steps done, last eval good | Force summary | No |
| Steps remaining, no failures | Continue | No |
| Consecutive failures at threshold | Stuck | No |
| Everything else | LLM decides | Yes |

## Working Memory

A single string threaded through all four prompts. Each LLM response includes an updated `working_memory` field. This is the loop's train of thought — it prevents context fragmentation across phases.

Every 3 iterations, a dedicated LLM call compresses the working memory to essential facts, discarding stale process notes.

## User Intervention

All interventions are real-time via PubSub — the GenServer processes them between phases.

| Action | Effect |
|---|---|
| **Pause** | Completes current task, then halts |
| **Resume** | Continues from where it paused |
| **Steer** | Free text injected into working memory with `[USER GUIDANCE]` prefix |
| **Step override** | Forces a specific skill + input, bypasses decision |
| **Add context** | Appended to working memory, persists across iterations |
| **Abort** | Kills running task, terminates session |

## Plan Validation

Before execution begins, every plan step is validated deterministically:

- Skill name must be present (not nil or empty)
- Skill must exist in the configured whitelist
- Steps failing validation are rejected and planning retries with the error injected

This catches malformed LLM output before it reaches the execution phase.

## Safety Mechanisms

| Mechanism | Default | Configurable |
|---|---|---|
| Max iterations | 15 | `reasoning.max_iterations` |
| Max LLM calls | 60 | `reasoning.max_llm_calls` |
| Time budget | ~300s per step | Proportional to plan size |
| Stuck threshold | 3 consecutive failures | `reasoning.stuck_threshold` |
| Confidence threshold | 0.7 | `reasoning.done_confidence_threshold` |
| Duplicate detection | 3x same {skill, input} | Automatic |
| Adjust oscillation | 3+ adjusts at high confidence | Forces final summary |
| Orphan cleanup | Boot sweep + terminate callback | Automatic |

## Score Trend

The last 3 evaluation scores are averaged and the slope is injected into the decision prompt as "improving", "stable", or "DEGRADING". This gives the model a signal about whether the current approach is working.

## Result Delivery

On completion:

1. Result stored to Memory (`kind: :reasoning`) with pgvector embedding
2. Optional Telegram/Discord notification via `reasoning.default_delivery` config
3. Skill outputs from each step are also embedded for future session context

## Configuration

All settings are editable from the Admin UI config page.

| Key | Default | Description |
|---|---|---|
| `reasoning.enabled` | `true` | Feature flag |
| `reasoning.llm_tier` | `local` | LLM tier: local, light, medium, heavy |
| `reasoning.max_iterations` | `15` | Max loop iterations |
| `reasoning.max_llm_calls` | `60` | Max LLM calls per session |
| `reasoning.skill_whitelist` | JSON array | Skills the loop may invoke |
| `reasoning.done_confidence_threshold` | `0.7` | Min confidence to accept done |
| `reasoning.stuck_threshold` | `3` | Consecutive failures before stuck |
| `reasoning.step_timeout_seconds` | `120` | Per-skill execution timeout |
| `reasoning.max_plan_steps` | `8` | Max steps in a plan |
| `reasoning.default_delivery` | `["memory"]` | Delivery channels on completion |

Prompt templates (`prompts.reasoning.planning`, `.execution`, `.evaluation`, `.decision`) are also editable at runtime. Leave empty to use defaults.

## Audit Trail

Every phase is recorded in the `reasoning_steps` table:

- LLM prompt and raw response
- Skill name, input, and output
- Rubric scores and quality assessment
- Decision and confidence
- Working memory snapshot
- Duration in milliseconds
- Errors

Sessions are tracked in `reasoning_sessions` with goal, status, plan, final result, iteration count, and LLM call count.

## Chat Page Integration

The chat page (`/chat`) operates in two modes:

- **Chat mode** — standard LLM conversation with memory context (unchanged)
- **Reasoning mode** — toggle to start a reasoning session with goal input, plan view, step timeline, intervention controls, and result panel

## Limitations

- **Output quality is model-dependent.** Local models (7B-14B) hallucinate when source material is thin. Routing to a stronger tier via `reasoning.llm_tier` improves quality.
- **No parallel skill execution.** Steps run sequentially.
- **Working memory degrades over long sessions** despite compression every 3 iterations.
- **Evaluation is LLM-judged.** Local models tend to rate their own output favorably. The deterministic pre-filter mitigates this for obvious cases.
