# Built-in Skills

AlexClaw ships with a comprehensive set of core skills. All are registered at boot and available immediately.

## Core Skills

| Skill | Description | Branches |
|---|---|---|
| `rss_collector` | Fetch RSS feeds, deduplicate, score relevance via LLM, notify | `on_items`, `on_empty`, `on_error` |
| `web_search` | Search DuckDuckGo and synthesize answers via LLM | `on_results`, `on_no_results`, `on_timeout`, `on_error` |
| `web_browse` | Fetch and summarize a URL, or answer questions about it | `on_success`, `on_not_found`, `on_timeout`, `on_error` |
| `research` | Deep research with memory context and LLM synthesis | `on_results`, `on_error` |
| `conversational` | Free-text LLM conversation with identity and memory | `on_success`, `on_error` |
| `telegram_notify` | Send workflow output to Telegram | `on_delivered`, `on_error` |
| `discord_notify` | Send workflow output to a Discord channel | `on_delivered`, `on_error` |
| `llm_transform` | Run a prompt template through the LLM (workflow glue step) | `on_success`, `on_error` |
| `api_request` | Generic REST client (GET/POST/PUT/PATCH/DELETE) | `on_2xx`, `on_4xx`, `on_5xx`, `on_timeout`, `on_error` |
| `github_security_review` | Fetch PR/commit diff, run LLM security analysis | `on_clean`, `on_findings`, `on_error` |
| `google_calendar` | Fetch upcoming Google Calendar events | `on_events`, `on_empty`, `on_error` |
| `google_tasks` | List and create Google Tasks | `on_tasks`, `on_empty`, `on_error` |
| `db_backup` | PostgreSQL backup with gzip compression and rotation | `on_success`, `on_error` |
| `shell` | Execute whitelisted OS commands (2FA-gated) | `on_success`, `on_error`, `on_timeout` |
| `web_automation` | Browser automation via headless Playwright sidecar | `on_success`, `on_timeout`, `on_error` |
| `coder` | Generate dynamic skills from natural language via local LLM | `on_created`, `on_workflow_created`, `on_error` |
| `send_to_workflow` | Send data to a workflow on another BEAM node | `on_sent`, `on_error` |
| `receive_from_workflow` | Gate: accepts remote triggers when placed as step 1 | `on_success`, `on_error` |

## Dynamic Skills (Shipped)

These are loaded from the skills volume at boot:

| Skill | Description |
|---|---|
| `elixir_source_scraper` | Fetch Elixir stdlib source from GitHub for pattern learning |
| `erlang_docs_scraper` | Fetch Erlang/OTP docs from GitHub into knowledge base |
| `lyse_scraper` | Scrape Learn You Some Erlang chapters into knowledge base |
| `skill_source_indexer` | Index existing skill source code into knowledge base |
| `system_info` | Returns UTC time, hostname, and Elixir version |
| `github_security_review_v2` | Enhanced GitHub PR/commit security review |
| `research_v2` | Enhanced deep research |
| `rss_v2` | RSS collector with full article fetch and configurable timeouts |
| `web_browse_v2` | Enhanced web browsing |
| `web_search_v2` | Enhanced DuckDuckGo search |
| `nvd_cve_monitor` | Fetches recent CVEs from NIST NVD 2.0 API |

## Notify Skills

`telegram_notify` and `discord_notify` pass through their input unchanged. This enables chained delivery — place multiple notify steps in sequence and each receives the same data.

## MCP Access

All skills are exposed as MCP tools with the `skill:` prefix. See [MCP Tools](../mcp/tools.md).
