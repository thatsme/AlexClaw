# Built-in Skills

AlexClaw ships with a comprehensive set of core skills. All are registered at boot and available immediately.

## Core Skills

Skills marked **External** fetch data from outside the system. Their output is automatically sanitized by `ContentSanitizer` before flowing through the workflow engine.

| Skill | Description | Branches | External |
|---|---|---|---|
| `rss_collector` | Fetch RSS feeds, deduplicate, score relevance via LLM, notify | `on_items`, `on_empty`, `on_error` | Yes |
| `web_search` | Search DuckDuckGo and synthesize answers via LLM | `on_results`, `on_no_results`, `on_timeout`, `on_error` | Yes |
| `web_browse` | Fetch and summarize a URL, or answer questions about it | `on_success`, `on_not_found`, `on_timeout`, `on_error` | Yes |
| `research` | Deep research with memory context and LLM synthesis | `on_results`, `on_error` | Yes |
| `conversational` | Free-text LLM conversation with identity and memory | `on_success`, `on_error` | — |
| `telegram_notify` | Send workflow output to Telegram | `on_delivered`, `on_error` | — |
| `discord_notify` | Send workflow output to a Discord channel | `on_delivered`, `on_error` | — |
| `llm_transform` | Run a prompt template through the LLM (workflow glue step) | `on_success`, `on_error` | — |
| `api_request` | Generic REST client (GET/POST/PUT/PATCH/DELETE) | `on_2xx`, `on_4xx`, `on_5xx`, `on_timeout`, `on_error` | Yes |
| `github_security_review` | Fetch a PR or commit diff — analysis is a following `llm_transform` step | `on_diff`, `on_empty`, `on_error` | Yes |
| `google_calendar` | Fetch upcoming Google Calendar events | `on_events`, `on_empty`, `on_error` | Yes |
| `google_tasks` | List and create Google Tasks | `on_tasks`, `on_empty`, `on_error` | Yes |
| `db_backup` | PostgreSQL backup with gzip compression and rotation (privileged) | `on_success`, `on_error` | — |
| `shell` | Execute allow-listed OS commands (privileged) | `on_success`, `on_error`, `on_timeout` | — |
| `web_automation` | Browser automation via the headless Playwright sidecar (privileged) | `on_success`, `on_error` | Yes |
| `coder` | Generation engine behind the Forge page — not usable as a workflow step | `on_created`, `on_partial`, `on_error` | — |
| `skill_source_indexer` | Index skill source into the knowledge base | `on_success`, `on_empty`, `on_error` | — |
| `send_to_workflow` | Send data to a workflow on another BEAM node | `on_sent`, `on_error` | — |
| `receive_from_workflow` | Gate: accepts remote triggers when placed as step 1 | `on_success`, `on_error` | — |

Privileged steps (`shell`, `coder`, `db_backup`, `web_automation`) run only in a run the scheduler starts, or one the admin UI starts with a 2FA code; a run of a workflow that contains one, started from a chat, MCP, a webhook or another node, is refused before it starts. `coder` is never a step: skills are generated on the Forge page.

## Composable Skills (v0.3.15+)

Pure-fetch and pure-LLM skills designed for single-responsibility workflows. Use these instead of the monolithic skills above.

!!! warning "Deprecation"
    `web_browse`, `web_search` and `rss_collector` are deprecated and kept for existing workflows; a later release removes them. Migrate to the composable pattern below.

### Pure Fetch (No LLM)

| Skill | Description | Branches | External |
|---|---|---|---|
| `web_fetch` | Fetch a URL, return extracted text (no LLM) | `on_success`, `on_not_found`, `on_timeout`, `on_error` | Yes |
| `web_search_fetch` | Search DuckDuckGo + fetch pages, return raw content (no LLM) | `on_results`, `on_no_results`, `on_timeout`, `on_error` | Yes |
| `rss_fetch` | Fetch RSS feeds, dedup, filter recent, return JSON items (no LLM) | `on_items`, `on_empty`, `on_error` | Yes |

### Pure LLM

| Skill | Description | Branches |
|---|---|---|
| `llm_transform` | Run a prompt template through the LLM | `on_success`, `on_error` |
| `llm_score` | Batch-score items for relevance via single LLM call | `on_items`, `on_empty`, `on_error` |

### Composable Workflow Examples

**Web research:**
```
web_search_fetch → llm_transform → telegram_notify
```

**Page summary:**
```
web_fetch → llm_transform → telegram_notify
```

**News briefing:**
```
rss_fetch → llm_score → llm_transform → telegram_notify
```

## Example Dynamic Skills

The repository's `test/fixtures/skills/` holds example dynamic skills (scrapers, an NVD CVE monitor, variants of the research and web skills) and a documented template, `skill_template.ex`. None is installed by default: a dynamic skill is loaded by uploading it on the Skills page. Some examples predate containment (they call `Task`, `System`, `File` or `:code` directly) and do not load until they use `SkillAPI.parallel_map/4` and `SkillAPI.module_docs/2` instead, or drop the call.

## Notify Skills

`telegram_notify` and `discord_notify` pass through their input unchanged. This enables chained delivery — place multiple notify steps in sequence and each receives the same data.

## MCP Access

Skills are not MCP tools. An MCP client runs workflows (`workflow:<name>`), and a skill runs inside a workflow. See [MCP Tools](../mcp/tools.md).
