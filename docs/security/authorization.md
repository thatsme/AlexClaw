# Agent Authorization Layer

The PolicyEngine provides context-aware authorization for all skill executions — both from workflows and MCP clients.

This page covers what a skill may do once it runs. Which entry point may ask
for a privileged action at all — the admin UI, a gateway, MCP, a webhook,
another node, the scheduler — and with what proof, is decided separately by
the control plane; see
[SECURITY.md](../../SECURITY.md#control-plane-elevation).

## AuthContext

Every authorization check builds an `AuthContext`:

| Field | Description |
|---|---|
| `caller` | Module or `"mcp:<tool_name>"` |
| `caller_type` | `:core`, `:dynamic`, or `:mcp` |
| `permission` | The specific permission being checked |
| `tool_name` | MCP tool name (nil for non-MCP) |
| `chain_depth` | Nesting level for cross-skill calls |
| `token` | Capability token (if present) |

## Evaluation Path

### Core Skills (`:core`)
Fast path — always allowed. No policy evaluation.

### Dynamic Skills (`:dynamic`)
Full evaluation:

1. **Chain depth** — denied if exceeding max depth (3)
2. **Capability token** — denied if token present but lacks the permission
3. **Policy rules** — rate limits, time windows, chain restrictions
4. **Permission list** — denied if permission not declared in `permissions/0`

### MCP Calls (`:mcp`)
Policy-only evaluation:

1. **Policy rules** — including `mcp_restriction` rules
2. No chain depth or token checks (MCP auth is at the transport layer)

## Capability Tokens

Macaroon-style HMAC-signed tokens that attenuate permissions:

- Minted per skill execution with the skill's declared permissions
- Workflow steps get scoped tokens
- Cross-skill invocation further restricts the token
- Verified via `CapabilityToken.verify/2`

## Policy Rules

Configurable rules stored in the `policies` table:

| Rule Type | Description |
|---|---|
| `rate_limit` | Max calls per time window |
| `time_window` | Allow/deny during specific hours |
| `chain_restriction` | Max chain depth for specific callers |
| `permission_override` | Force deny for specific permissions |
| `mcp_restriction` | Block MCP tools by name pattern |

## Content Sanitization Integration

The authorization layer works alongside `AlexClaw.ContentSanitizer` for external-facing skills. The workflow executor checks `SkillRegistry.external?/1` after each skill execution — output from external skills passes through a 7-layer heuristic sanitizer (hidden HTML/CSS detection, zero-width unicode stripping, pattern matching, imperative tone analysis) before flowing to the next step. Pre-LLM sanitization also occurs inside `web_browse` and `web_search` before content reaches the LLM prompt. See [SECURITY.md](../../SECURITY.md#content-sanitization-prompt-injection-defense) for the full defense model.

## Audit Logging

All authorization decisions are logged to `auth_audit_log`:

- Caller identity and type
- Permission checked
- Result (allow/deny with reason)
- Timestamp

View in **Admin > Policies > Audit Log**.
