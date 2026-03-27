# Dynamic Hot-Loading

Load custom skills at runtime — no code changes, no Docker rebuild, no restart. Drop an `.ex` file into the skills volume or upload via the Admin UI.

## Loading a Skill

### Via Admin UI

1. Go to **Admin > Skills**
2. Click **Upload Skill**
3. Select your `.ex` file
4. Confirm with 2FA (TOTP code sent to Telegram/Discord)
5. The skill compiles into the running VM immediately

### Via Volume Mount

1. Place the `.ex` file in the skills Docker volume
2. The skill is loaded automatically on next boot
3. To load without restart, use the Admin UI reload button

## Security Layers

Dynamic skills are sandboxed with multiple layers of protection:

### Permission Sandbox

Skills declare their required permissions via `permissions/0`. Undeclared permissions are denied at runtime by the PolicyEngine:

```elixir
def permissions, do: [:web_read, :llm]
# This skill can only make web requests and LLM calls
# Attempting :memory_write without declaring it → denied
```

### Capability Tokens

Macaroon-style HMAC-signed tokens attenuate permissions through the call chain. Workflow steps get scoped tokens; cross-skill invocation further restricts.

### Process Isolation

Dynamic skills execute in spawned processes via `SafeExecutor`, isolating auth state from the caller.

### Namespace Enforcement

Module must be `AlexClaw.Skills.Dynamic.*` — other namespaces are rejected.

### Integrity Verification

SHA256 checksum is stored on load and verified on boot. Tampered files are skipped with a Telegram alert.

### 2FA Gate

Every skill load, unload, and reload requires TOTP verification. No exceptions, no bypass.

## Lifecycle

| Action | How | 2FA Required |
|---|---|---|
| Load | Upload via Admin UI or place in volume | Yes |
| Reload | Admin UI reload button | Yes |
| Unload | Admin UI unload button | Yes |
| Boot load | Automatic from volume on container start | No (integrity verified) |

## Persistence

Dynamic skills survive container restarts:

- Source code stored in the database
- Files also stored on the Docker volume
- On boot: files are verified (SHA256) and compiled into the VM
- Tampered files are skipped with an alert

## MCP Integration

Dynamically loaded skills automatically appear as MCP tools. Connected MCP clients receive a `tools/list_changed` notification and can re-fetch the tool list without reconnecting.
