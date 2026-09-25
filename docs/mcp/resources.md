# MCP Resources

AlexClaw exposes its internal data stores as MCP resources via URI templates. Clients can browse and read data using the standard `resources/list` and `resources/read` methods.

## URI Templates

| URI Template | Data | MIME Type |
|---|---|---|
| `alexclaw://resources/{id}` | RSS feeds, websites, documents, APIs | `application/json` |
| `alexclaw://knowledge/{id}` | Knowledge base entries (docs, guides) | `application/json` |
| `alexclaw://memory/{id}` | News items, facts, observations | `application/json` |
| `alexclaw://workflows/{id}` | Workflow definitions with steps | `application/json` |
| `alexclaw://runs/{id}` | Workflow execution history | `application/json` |
| `alexclaw://config/{key}` | Settings (sensitive values redacted) | `application/json` |

## Browsing

Use `list` as the ID to browse all entries:

```
alexclaw://resources/list    → all RSS feeds, websites, etc.
alexclaw://knowledge/list    → 50 most recent knowledge entries
alexclaw://memory/list       → 50 most recent memory entries
alexclaw://workflows/list    → all workflow definitions
alexclaw://runs/list         → 50 most recent workflow runs
alexclaw://config/list       → all settings (sensitive values redacted)
```

## Reading by ID

Pass a numeric ID to read a specific entry:

```
alexclaw://resources/3       → Ars Technica RSS feed
alexclaw://knowledge/42      → specific knowledge entry
alexclaw://workflows/1       → Tech News Digest with all steps
alexclaw://runs/100          → specific workflow run with step results
```

## Searching

Knowledge and memory support search queries with the `search:` prefix:

```
alexclaw://knowledge/search:GenServer    → knowledge entries matching "GenServer"
alexclaw://memory/search:market          → memory entries matching "market"
```

Search uses the same hybrid search (vector + keyword) as the admin UI.

## Config by Key

Config resources use the dotted key name instead of a numeric ID:

```
alexclaw://config/skills.rss.relevance_threshold
alexclaw://config/mcp.api_key    → returns [REDACTED] (sensitive)
```

## Sensitive Data

No secret value leaves through MCP. One rule applies to every read, whether an
entry is read alone or listed:

| Data | What MCP returns |
|---|---|
| Settings marked sensitive (API keys, bot tokens, OAuth secrets, the webhook secret, the MCP key, 2FA secrets) | `[REDACTED]` as the value, in `config/list` and in `config/<key>` alike. The key, type and category are still visible |
| A workflow step's secret config keys (a notify step's `bot_token`, an API step's `headers`) | `[REDACTED]`; the step's other config is returned as it is |
| A resource's `auth` block (the header an API resource sends) | Not returned |
| A password in a resource's URL (`user:password@host`) | Replaced: `https://REDACTED@host/…` |
| Values a web-automation recording captured, and those steps' descriptions | `[REDACTED]` |

Skills reading resources through the skill API get the same redaction.

## Response Format

All resources return JSON. Example for a workflow:

```json
{
  "id": 1,
  "name": "Tech News Digest",
  "description": "Collects news from RSS feeds...",
  "enabled": true,
  "schedule": null,
  "default_provider": "LM Studio",
  "steps": [
    {
      "position": 1,
      "name": "Collect News",
      "skill": "rss_collector",
      "llm_tier": "light",
      "config": {"force": false, "threshold": 0.3},
      "routes": []
    }
  ]
}
```

## Error Handling

| Error | Cause |
|---|---|
| `not found: <type> <id>` | Entry doesn't exist |
| `Invalid ID: <id>` | Non-numeric ID (except `list`, `search:*`, config keys) |
| `Unknown resource URI` | URI doesn't match any template |
