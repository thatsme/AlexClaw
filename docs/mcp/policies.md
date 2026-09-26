# MCP Policy Enforcement

MCP tool calls pass through the same PolicyEngine used for skill authorization, with a dedicated `:mcp` caller type and the `mcp_restriction` rule type for fine-grained tool blocking.

## Auth Flow

```
Bearer token (transport layer)
    │
    ▼
McpAuth Plug ── validates the key's HMAC against the stored fingerprint
    │
    ▼
PolicyEngine.evaluate/2 ── evaluates mcp_restriction policies
    │
    ▼
ControlPlane.perform(:run_workflow) ── refuses protected, disabled or privileged runs; audits
    │
    ▼
Workflows.Executor
```

## MCP Caller Type

When a tool is invoked via MCP, the PolicyEngine receives an `AuthContext` with:

- `caller_type: :mcp`
- `caller: "mcp:workflow:<name>"`
- `tool_name: "workflow:<name>"`
- `permission: :execute`

The MCP evaluation skips chain-depth and capability-token checks (no skill runs directly from MCP) and evaluates all policy rules, including `mcp_restriction`.

## Creating Restriction Policies

Policies are created on **Admin > Policies** with the page unlocked (rule type **MCP Restriction**); saving is audited and takes effect at once.

### Config Fields

| Field | Type | Description |
|---|---|---|
| `tool_pattern` | string | The tool name, or part of it |
| `match` | string | `"exact"` — the whole name; anything else, or absent — a substring (`String.contains?/2`) |
| `action` | string | `"deny"` blocks the tool; any other value lets it through |

### Pattern Matching

| Pattern | Match | Blocks |
|---|---|---|
| `workflow:Nightly Backup Report` | `exact` | that workflow |
| `workflow:` | substring | every workflow |
| `Digest` | substring | every workflow whose name contains "Digest" |

Privileged skills need no MCP policy: a workflow containing one is refused from MCP by the control plane.

### Non-MCP Callers

The `mcp_restriction` rule type is **ignored** for non-MCP callers (`:core` and `:dynamic`). Policies are caller-type-aware — MCP restrictions don't affect Telegram commands or workflow execution.

## Audit Logging

Every MCP run is recorded by the control plane (caller `mcp:<client>`, permission `control_plane.run_workflow`), allowed or refused. The policy check is recorded too, allowed or denied, with caller `"mcp:workflow:<name>"` — quoted, as `inspect/1` writes it, so `LIKE 'mcp:%'` does not match it and `LIKE '%mcp:%'` does. View both in **Admin > Policies > Audit Log**.
