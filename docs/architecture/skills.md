# Skills

A skill is an Elixir module implementing the `AlexClaw.Skill` behaviour. Skills
are the unit of work: a workflow step runs one, the dispatcher routes a command
to one, and the reasoning loop picks between them.

## The behaviour

`run/1` is the only required callback. Optional ones describe the skill to the
rest of the system:

| Callback | Used for |
|---|---|
| `description/0` | Catalogue listings, and the reasoning loop's planning prompt |
| `routes/0` | The branches this skill can return, for conditional wiring |
| `permissions/0` | What the skill may ask `SkillAPI` to do on its behalf |
| `version/0` | Reload safety — loading the same version twice is refused |
| `external/0` | Marks a skill that fetches untrusted data |
| `step_fields/0` and friends | Which fields the workflow step editor should render |

A skill returns `{:ok, result, :branch}` to steer the next step, or
`{:ok, result}` to fall through.

`AlexClaw.Workflows.SkillRegistry` owns the catalogue in ETS: module, type,
permissions, routes and the external flag. The step editor renders itself from
`SkillRegistry.get_skill_meta/1`, so a skill that uses no model declares
`step_fields: [:config]` and the editor shows no tier, provider or prompt
template. No skill metadata is hardcoded in the LiveView.

**`step_fields/0` must list only what `run/1` actually reads.** A field the
editor renders and the skill discards is a control that does nothing.

## What a skill may do

Every side effect goes through `AlexClaw.Skills.SkillAPI`, which checks the
calling module's declared permissions first. The full function list, what each
permission grants, and which calls redact or refuse data is in the
[Skill API Reference](../skills/skill-api.md).

Two properties are worth knowing here because they shape how skills are
composed: secrets are not readable through the config call, and four privileged
core skills cannot be invoked from inside another skill. Both are stated in
[SECURITY.md](https://github.com/thatsme/AlexClaw/blob/main/SECURITY.md).

## External skills

A skill fetching data from outside declares `def external, do: true`. The
executor then passes its output through `AlexClaw.ContentSanitizer` before the
result reaches the next step, so injected instructions are stripped structurally
rather than by remembering to add a sanitise step.

Dynamic skills are AST-scanned at load: an HTTP or socket call without the
declaration is rejected.

## Catalogue

| Skill | Module | Role |
|---|---|---|
| `rss_fetch` | `RssFetch` | Fetch feeds, deduplicate, filter recent — no model |
| `llm_score` | `LlmScore` | Batch-score items in one call and filter by threshold |
| `rss_collector` | `RSSCollector` | Fetch, score and notify in one step |
| `web_fetch` | `WebFetch` | Fetch a URL and extract text — no model |
| `web_search_fetch` | `WebSearchFetch` | Search and fetch pages — no model |
| `web_search` | `WebSearch` | Search, fetch, and synthesise an answer |
| `web_browse` | `WebBrowse` | Fetch and summarise a URL |
| `research` | `Research` | Research a question against memory and knowledge |
| `conversational` | `Conversational` | Free-text conversation with identity and recent context |
| `llm_transform` | `LLMTransform` | Run a prompt template over the previous step |
| `api_request` | `ApiRequest` | REST client resolving URL and auth from a resource |
| `github_security_review` | `GitHubSecurityReview` | Fetch a PR or commit diff — analysis is a following step |
| `google_calendar`, `google_tasks` | `GoogleCalendar`, `GoogleTasks` | Google integration |
| `telegram_notify`, `discord_notify` | `TelegramNotify`, `DiscordNotify` | Deliver output to a chat |
| `send_to_workflow`, `receive_from_workflow` | `SendToWorkflow`, `ReceiveFromWorkflow` | Cross-node workflow handoff |
| `web_automation` | `WebAutomation` | Browser recording and headless replay via the sidecar |
| `db_backup` | `DbBackup` | Compressed PostgreSQL dump with rotation |
| `shell` | `Shell` | Whitelisted OS commands for container introspection |
| `coder` | `Coder` | Generate a new skill from a goal |

The last four are privileged: they reach the host, the filesystem or the
database, and are treated differently from everywhere else in the system.

The composable pattern is worth noting: `rss_fetch → llm_score` does what
`rss_collector` does in one step, but lets a workflow put its own steps in
between. Fetching and reasoning are separable on purpose.

## Dynamic skills

A dynamic skill is compiled into the running VM from a file in the skills
volume. The source is parsed and vetted **as a syntax tree before anything is
compiled**, because compiling a module runs its body.

```
                  source file
                       │
                  parse to AST
                       │
              shape and namespace checks
                       │
                   compile
                       │
              contract validation
                       │
                  registered
```

Loading a skill is equivalent to deploying code, and is gated accordingly. What
the gate is, what the AST checks reject, and what containment does and does not
guarantee are stated in
[SECURITY.md](https://github.com/thatsme/AlexClaw/blob/main/SECURITY.md).

## Generated skills

`/coder` and the Forge page generate a skill from a natural-language goal using
the local model, at no cloud cost.

`AlexClaw.Skills.CodeGenerator` runs the loop: build a prompt with retrieved
context, ask the model, extract the code block, and stage it — **into a pending
directory, never the live one**. `AlexClaw.Skills.CallPolicy` then reads the
staged source and reports every remote call it makes.

What happens next depends on that verdict:

- **Contained** — the module calls only things on the allowlist and declares
  only permissions inside the unattended ceiling. It is promoted and loaded,
  recorded as approved by containment.
- **Not contained** — the violations are fed back to the model as a retry hint
  naming the calls to replace. If it still will not fit, the file stays staged
  and a second factor is required to load it.

Containment is re-judged on every boot for skills approved that way, so an
allowlist tightened in a release takes effect on code nobody re-approved.

The allowlist, the permission ceiling, and the precise limits of what
containment proves are owned by
[SECURITY.md](https://github.com/thatsme/AlexClaw/blob/main/SECURITY.md). It is
worth reading before enabling generation: the local model producing the code is
part of the trust boundary, and a goal can arrive as a chat message.
