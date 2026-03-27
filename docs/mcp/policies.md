# MCP Policy Enforcement

MCP tool calls pass through the same PolicyEngine used for skill authorization, with a dedicated `:mcp` caller type and the `mcp_restriction` rule type for fine-grained tool blocking.

## Auth Flow

```
Bearer token (transport layer)
    │
    ▼
McpAuth Plug ── validates token against mcp.api_key
    │
    ▼
PolicyEngine.evaluate/2 ── evaluates mcp_restriction policies
    │
    ▼
CapabilityToken ── minted per-skill execution
    │
    ▼
Skill.run()
```

## MCP Caller Type

When a tool is invoked via MCP, the PolicyEngine receives an `AuthContext` with:

- `caller_type: :mcp`
- `caller: "mcp:skill:<name>"` or `"mcp:workflow:<name>"`
- `tool_name: "skill:<name>"` or `"workflow:<name>"`
- `permission: :execute`

The MCP evaluation path:

- **Skips** chain depth checks (no nested skill calls from MCP)
- **Skips** capability token validation (token is minted after policy check)
- **Evaluates** all policy rules, including `mcp_restriction`

## Creating Restriction Policies

To block specific tools for MCP clients, insert a policy with `rule_type: "mcp_restriction"`:

```sql
INSERT INTO policies (name, rule_type, config, enabled, inserted_at, updated_at)
VALUES (
  'Block shell via MCP',
  'mcp_restriction',
  '{"tool_pattern": "shell", "action": "deny"}',
  true,
  NOW(), NOW()
);
```

### Config Fields

| Field | Type | Description |
|---|---|---|
| `tool_pattern` | string | Substring match against the tool name |
| `action` | string | `"deny"` (default) — blocks the tool |

### Pattern Matching

The `tool_pattern` is matched using `String.contains?/2` against the full tool name:

| Pattern | Blocks |
|---|---|
| `"shell"` | `skill:shell` |
| `"skill:db"` | `skill:db_backup` |
| `"workflow:"` | All workflows |
| `"notify"` | `skill:telegram_notify`, `skill:discord_notify` |

### Non-MCP Callers

The `mcp_restriction` rule type is **ignored** for non-MCP callers (`:core` and `:dynamic`). Policies are caller-type-aware — MCP restrictions don't affect Telegram commands or workflow execution.

## Audit Logging

All MCP tool invocations are logged to the `auth_audit_log` table:

- **Allowed** calls are logged with the tool name and caller
- **Denied** calls are logged with the denial reason

View audit entries in **Admin > Policies > Audit Log**, or query directly:

```sql
SELECT * FROM auth_audit_log
WHERE caller LIKE 'mcp:%'
ORDER BY inserted_at DESC
LIMIT 20;
```

## Examples

### Block all workflow execution via MCP

```sql
INSERT INTO policies (name, rule_type, config, enabled, inserted_at, updated_at)
VALUES (
  'MCP: no workflows',
  'mcp_restriction',
  '{"tool_pattern": "workflow:", "action": "deny"}',
  true, NOW(), NOW()
);
```

### Block dangerous skills

```sql
INSERT INTO policies (name, rule_type, config, enabled, inserted_at, updated_at)
VALUES
  ('MCP: no shell', 'mcp_restriction', '{"tool_pattern": "shell", "action": "deny"}', true, NOW(), NOW()),
  ('MCP: no coder', 'mcp_restriction', '{"tool_pattern": "coder", "action": "deny"}', true, NOW(), NOW()),
  ('MCP: no db_backup', 'mcp_restriction', '{"tool_pattern": "db_backup", "action": "deny"}', true, NOW(), NOW());
```
