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

## Credentials in steps

A step's credential fields — the keys its skill declares in
`secret_config_keys/0` (every header of an API Request step, a Telegram Notify
step's own `bot_token`), and the fill values of a web-automation recipe — are
stored as secrets in OpenBao, bound when they are entered to the host the step
sends them to. For an API Request step addressed through its workflow's API
resource (a `{base_url}` URL, or a `path`), that is the resource's host. A step
with a credential and no such host is refused. The step row holds references;
at run time the skill receives placeholders, never values, and the value is
attached at send, for the host the request actually goes to. See
[SECURITY.md](https://github.com/thatsme/AlexClaw/blob/main/SECURITY.md#secrets-in-openbao).

## Triggering

| Method | How |
|---|---|
| Scheduled | Cron expressions synced to Quantum by `Workflows.SchedulerSync` |
| Telegram/Discord | `/run <id or name>` |
| Admin UI | Run button on the workflow page |
| MCP | `workflow:<name>` tool call |
| GitHub webhook | The workflow named in `github.review_workflow` |
| Another node | `send_to_workflow` to a workflow whose step 1 is `receive_from_workflow` |

Every trigger but the scheduler starts the run through
`ControlPlane.perform/3`, which audits it, allowed or refused. A run started
from the admin UI, a chat, the webhook or another node executes under
`AlexClaw.TaskSupervisor`, so a crash is supervised rather than lost; an MCP
call runs the workflow and waits for its result.

A workflow marked `Requires 2FA` takes a code for each run — typed in the
admin UI, or answered in the chat that asked — and cannot be scheduled; MCP,
the webhook and other nodes cannot start it. A workflow with a privileged step
(`shell`, `coder`, `db_backup`, `web_automation`) runs only when the scheduler
starts it or the admin UI starts it with a code; from anywhere else it is
refused before any step runs.
[SECURITY.md](https://github.com/thatsme/AlexClaw/blob/main/SECURITY.md) states
what these gates cover and how they behave when 2FA is not configured.

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

**Export** (`GET /workflows/:id/export`, or the Export button in the Admin UI, with the page unlocked) produces a JSON file containing:

- Workflow definition (name, description, schedule, provider, node, metadata)
- All steps with position, skill, config, prompt template, LLM tier/model, routes, input_from
- Full resource definitions (name, type, URL, content, tags, metadata, enabled)

No database IDs or timestamps — the file is portable across instances.

No credentials either: every config key a skill declares secret (`secret_config_keys/0`, e.g. Telegram Notify's `bot_token`, API Request's `headers`) is written as the placeholder `<secret not exported>`. A map keeps its keys, so an API Request step still shows which headers it needs.

**Import** (file upload in Admin UI) validates the JSON structure, then:

1. Creates the workflow (disabled by default, `(imported N)` suffix on name conflicts)
2. Creates steps with their original positions preserved. Secret config values arrive as placeholders and are left empty; each such step is marked **needs secrets** in the editor, naming the keys, until they are filled in
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
