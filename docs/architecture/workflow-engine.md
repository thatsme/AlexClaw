# Workflow Engine

Workflows are **linear pipelines** with conditional branching. The executor walks the step graph sequentially — each step has exactly one successor per branch.

## Execution Model

A step's output feeds into the next step's input, forming a single execution path per run. There is no fan-out (one step cannot broadcast to multiple parallel successors).

```
Step 1: Fetch RSS feeds
  → on_items: Step 2 (score items)
  → on_empty: Step 4 (send "no news today")
  → on_error: Step 5 (notify failure)
```

## Conditional Branching

Each skill declares its possible outcomes via the `routes/0` callback:

```elixir
def routes, do: [:on_items, :on_empty, :on_error]
```

Skills return a triple tuple indicating which outcome occurred:

```elixir
{:ok, result, :on_items}    # branch taken
{:ok, result}               # no branch (linear fallthrough)
{:error, reason}            # error
```

The executor matches the branch against the step's route configuration to determine the next step. Only one branch is followed per step. Steps without routes fall through to the next position.

## Step Wiring

By default, each step receives the output of the previous step. The `input_from` field enables non-linear wiring — a step can pull its input from any earlier step by position number, enabling fan-in patterns.

## Triggering

| Method | How |
|---|---|
| Scheduled | Cron expressions synced to Quantum by `SchedulerSync` |
| Telegram/Discord | `/run <id or name>` (supports 2FA gating) |
| Admin UI | Run button on workflow page |
| MCP | `workflow:<name>` tool call |

## Resilience

Each step has configurable resilience controls:

| Setting | Options | Description |
|---|---|---|
| On Circuit Open | `halt`, `skip`, `fallback` | What to do when the skill's breaker is open |
| On Missing Skill | `halt`, `skip` | What to do when the skill is not loaded |
| Fallback Skill | skill name | Alternative skill for `fallback` mode |

## Circuit Breaker Integration

The circuit breaker wraps skill execution transparently in the Executor. Skills are unaware of the breaker:

- 3 consecutive failures → circuit opens → Telegram notification
- After 5 minutes → half-open → one test call
- Test succeeds → circuit closes → Telegram notification

## Content Sanitization

The executor integrates with `AlexClaw.ContentSanitizer` for prompt injection defense. Two sanitization points:

**Pre-LLM (inside skills):** External skills like `web_browse` and `web_search` sanitize fetched content before building the LLM prompt. Injection payloads are stripped before the model sees them.

**Post-LLM (executor level):** After each skill returns, the executor checks `SkillRegistry.external?/1`. If the skill is tagged external, the output passes through the 7-layer sanitizer (hidden HTML/CSS detection, zero-width unicode stripping, pattern matching, imperative tone heuristic) before flowing to the next step.

This is transparent to workflow authors — no sanitize step to add, no step to forget. External data is always sanitized structurally.

## Export / Import

Workflows can be exported as self-contained JSON files and imported on any instance.

**Export** (`GET /workflows/:id/export` or "Export" button in Admin UI) produces a JSON file containing:

- Workflow definition (name, description, schedule, provider, node, metadata)
- All steps with position, skill, config, prompt template, LLM tier/model, routes, input_from
- Full resource definitions (name, type, URL, content, tags, metadata, enabled)

No database IDs or timestamps — the file is portable across instances.

**Import** (file upload in Admin UI) validates the JSON structure, then:

1. Creates the workflow (disabled by default, `(imported N)` suffix on name conflicts)
2. Creates steps with their original positions preserved
3. For each resource: links to an existing match by name + URL, or creates a new resource

The JSON file can be edited manually — add resources, modify steps, change configs — before importing.

## Live Run Tracking

The `WorkflowRegistry` (GenServer + ETS) tracks every running workflow:

- Active run visibility with current step and start time
- Cancellation via Admin UI or `/cancel <run_id>` command
- Crash cleanup — monitors PIDs, marks orphaned runs as failed
- Real-time PubSub events drive the Admin UI active runs panel

## Execution Outcome Annotation

Every skill execution is recorded in `skill_outcomes` with timing, output snapshot, and metadata. Users can rate outcomes via `/rate <run_id>` (thumbs up/down). Skills can query past outcomes for episodic memory and self-improvement.
