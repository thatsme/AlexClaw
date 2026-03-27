# MCP Tools

All registered skills and enabled workflows are automatically exposed as MCP tools. Clients discover them via the standard `tools/list` method.

## Naming Convention

| Type | MCP Tool Name | Example |
|---|---|---|
| Core skill | `skill:<name>` | `skill:web_search` |
| Dynamic skill | `skill:<name>` | `skill:system_info` |
| Workflow | `workflow:<name>` | `workflow:Tech News Digest` |

## Tool Discovery

Tools are registered on the Anubis frame during `init/2`. Each tool includes:

- **name** — the `skill:` or `workflow:` prefixed identifier
- **description** — from the skill module's `description/0` callback, or the workflow's description field
- **input_schema** — Peri-compatible type definitions converted to JSON Schema by Anubis

Dynamic skills are tagged with `[dynamic]` in their description.

## Dynamic Refresh

When skills are loaded, unloaded, or reloaded at runtime, the MCP server:

1. Receives a PubSub event on the `"skills:registry"` topic
2. Re-registers all tools on the frame
3. Sends a `notifications/tools/list_changed` notification to connected clients
4. Clients automatically re-fetch the tool list

This means newly loaded dynamic skills appear in MCP clients without reconnecting.

## Input Schema

Core skills have typed config schemas. For example, `skill:web_search`:

```json
{
  "input": { "type": "string", "description": "Input data passed to the skill" },
  "config": { "type": "object" },
  "query": { "type": "string", "description": "Search query string" },
  "max_results": { "type": "integer", "description": "Maximum results to return" }
}
```

Dynamic skills use a generic schema with `input` and `config` fields.

## Execution Flow

When a client calls a tool:

1. **Resolve** — skill name looked up in SkillRegistry, or workflow found by name
2. **Policy check** — `PolicyEngine.evaluate/2` with `:mcp` caller type (see [Policy Enforcement](policies.md))
3. **Execute** — skill runs in a supervised task with a capability token
4. **Timeout** — configurable via `mcp.tool_timeout_ms` (default 30 seconds)
5. **Response** — result mapped to `Anubis.Server.Response` format

## Timeout Handling

Tool execution has a configurable timeout:

```
Config key: mcp.tool_timeout_ms
Default: 30000 (30 seconds)
```

If a tool exceeds the timeout, the task is shut down and an error response is returned:

```json
{"type": "text", "text": "Tool execution timed out", "isError": true}
```

## Error Responses

| Error | MCP Error Code | Cause |
|---|---|---|
| Unknown skill | `-32602` (invalid params) | Skill not in registry |
| Unknown workflow | `-32602` (invalid params) | Workflow not found |
| Policy denied | execution error | `mcp_restriction` policy matched |
| Timeout | execution error | Exceeded `mcp.tool_timeout_ms` |
| Crash | execution error | Skill raised an exception |

## Available Tools

The exact tool list depends on your registered skills. Use `tools/list` from your MCP client, or check the `/metrics` endpoint for the current count.

Typical installation exposes ~29 skill tools and ~5 workflow tools.
