# Workflow Engine

Workflows are **linear pipelines** with conditional branching.
`AlexClaw.Workflows.Executor` walks the step graph sequentially — each step has
exactly one successor per branch.

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
| Scheduled | Cron expressions synced to Quantum by `Workflows.SchedulerSync` |
| Telegram/Discord | `/run <id or name>` |
| Admin UI | Run button on the workflow page |
| MCP | `workflow:<name>` tool call |

Every run executes under `AlexClaw.TaskSupervisor`, so a crash is supervised
rather than lost. A workflow marked as requiring a second factor raises a
challenge first, on every one of these paths —
[SECURITY.md](https://github.com/thatsme/AlexClaw/blob/main/SECURITY.md) states
what that gate covers and how it behaves when 2FA is not configured.

## The LLM step

`AlexClaw.Workflows.LLMTransform` is the generic "run a prompt over the previous
step's output" step, used wherever a workflow needs a model rather than a
purpose-built skill. It substitutes `{input}` and `{resources}` into the step's
prompt template and carries a set of named presets — summarise, bullet points,
code review, translate, classify, extract.

## Provider routing

Three levels decide which model a step uses, most specific winning:

1. **Step** — the `llm_tier` and `llm_model` fields on the workflow step
2. **Workflow** — the `default_provider` field
3. **Global** — the tier fallback chain in the [LLM Router](llm-router.md)

Not every skill reads these; a skill declares which step fields it honours
through `step_fields/0`, and the editor shows only those.

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

`AlexClaw.Workflows.Registry` (GenServer + ETS) tracks every running workflow:

- Active run visibility with current step and start time
- Cancellation via Admin UI or `/cancel <run_id>` command
- Crash cleanup — monitors PIDs, marks orphaned runs as failed
- Real-time PubSub events drive the Admin UI active runs panel

## Execution Outcome Annotation

Every skill execution is recorded in `skill_outcomes` with timing, a truncated
output snapshot, and metadata. Outcomes start neutral and are annotated with
`/rate <run_id>` (`+`/`-`, `up`/`down`, or a thumb). A rating can target a whole
run or one step.

Skills read past outcomes back through `SkillAPI.skill_outcomes/3`, which is the
foundation for episodic memory and self-improvement loops.

## Notifications

A workflow containing a notify step gets a start notification when it begins,
and a failure notification if a step fails before reaching that step.
