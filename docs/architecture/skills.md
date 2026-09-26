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

Dynamic skills reach the outside **only** through `AlexClaw.Skills.SkillAPI`,
which checks the running skill's declared permissions. Their source may call
nothing but `SkillAPI` and an allowlist of modules and functions; this
containment is checked on the syntax tree at every load and at every boot, and
no approval lifts it. Core skills are part of the release and are trusted
code. What containment covers and where it stops is stated in
[SECURITY.md](https://github.com/thatsme/AlexClaw/blob/main/SECURITY.md#dynamic-skill-loading).

The full function list, what each permission grants, and which calls redact or
refuse data is in the [Skill API Reference](../skills/skill-api.md).

Two properties are worth knowing here because they shape how skills are
composed: secrets are not readable through the config call, and four privileged
core skills cannot be invoked from inside another skill. Both are stated in
[SECURITY.md](https://github.com/thatsme/AlexClaw/blob/main/SECURITY.md).
Three of those four (`shell`, `db_backup`, `web_automation`) run as workflow
steps only when the scheduler starts the run, or the admin UI starts it with a
2FA code; a run started from a chat, MCP, a webhook or another node is refused
before any step runs. The fourth, `coder`, is not a workflow step at all.

## External skills

A skill fetching data from outside declares `def external, do: true`. The
executor then passes its output through `AlexClaw.ContentSanitizer` before the
result reaches the next step, so the filtering happens by structure rather than
by remembering to add a sanitise step.

The sanitizer is heuristic: it filters known injection shapes, it does not
guarantee their absence. Its layers and its known limitations are listed in
[SECURITY.md](https://github.com/thatsme/AlexClaw/blob/main/SECURITY.md), which
also covers what the load-time scan does and does not catch about undeclared
external calls.

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
| `skill_source_indexer` | `SkillSourceIndexer` | Index skill source into the knowledge base |
| `web_automation` | `WebAutomation` | Browser recording and headless replay via the sidecar |
| `db_backup` | `DbBackup` | Compressed PostgreSQL dump with rotation |
| `shell` | `Shell` | Whitelisted OS commands for container introspection |
| `coder` | `Coder` | The generation engine behind the Forge page — not usable as a workflow step |

The last four are privileged: they reach the container, its filesystem or the
database, and are treated differently from everywhere else in the system.

The composable pattern is worth noting: `rss_fetch → llm_score` does what
`rss_collector` does in one step, but lets a workflow put its own steps in
between. Fetching and reasoning are separable on purpose.

## Dynamic skills

A dynamic skill is compiled into the running VM from an uploaded file, staged
outside the live directory until a 2FA code approves it. The source is parsed
and vetted **as a syntax tree before anything is compiled**, because compiling
a module runs its body.

```
                  uploaded file (staged)
                       │
                  parse to AST
                       │
              shape and namespace checks
                       │
                  containment (allowlist)
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

The Forge page generates a skill from a natural-language goal. **It offers a
provider selector** listing every configured provider: the default is local,
but choosing a cloud provider puts a third party in the loop for code that will
be compiled into the running VM. Generation is an authoring action: it needs the
page unlocked with a 2FA elevation, and it is not available from a chat, MCP or
a workflow step.

`AlexClaw.Skills.CodeGenerator` runs the loop: build a prompt with retrieved
context, ask the model, extract the code block, and stage it — **into a pending
directory, never the live one**. `AlexClaw.Skills.CallPolicy` then reads the
staged source and reports every remote call it makes. A verdict short of loading
is fed back to the model as a retry hint; when the retries do not fix it, the
last verdict stands:

- **Contained, within the unattended permissions** — every call is on the
  allowlist and the declared permissions are inside the unattended ceiling. It
  is promoted and loaded, recorded as approved by containment.
- **Contained, more permissions** — the file stays staged and a 2FA code
  approves its permissions; the approval screen names the risky ones.
- **Not contained** — code that calls outside the allowlist never loads: no
  approval allows it.

Every dynamic skill is re-judged against the current allowlist at every boot,
so an allowlist tightened in a release applies to code already loaded.

The allowlist, the permission ceiling, and the precise limits of what
containment proves are owned by
[SECURITY.md](https://github.com/thatsme/AlexClaw/blob/main/SECURITY.md#dynamic-skill-loading).
The model producing the code is part of the trust boundary.
