# Dynamic Hot-Loading

Load custom skills at runtime — no code changes, no Docker rebuild, no restart. A skill is uploaded on the Admin UI's Skills page.

## Loading a Skill

1. Go to **Admin > Skills** and unlock the page (2FA elevation)
2. Click **Upload Skill** and select the `.ex` file — it is staged outside the live skills directory
3. The approval screen lists the skill's permissions and flags the risky ones; type a TOTP code to approve that load
4. The skill is checked (syntax tree, containment), compiled into the running VM and registered

A file placed in the skills volume by hand is not loaded: at boot, only skills registered through an approved upload are loaded, each verified against its stored checksum.

## Security Layers

Dynamic skills are bounded by several layers:

### Containment

Every remote call in the source must be to `SkillAPI` or the allowlist of pure modules ([Skill API Reference](skill-api.md#what-a-skills-source-may-call)). Checked at every load and every boot; a skill that fails it does not load, whatever was approved.

### Permissions

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

Loading and reloading a skill each take a TOTP code typed on the Skills page, for that action alone. Unloading needs the page unlocked (a 2FA elevation). None of it is possible from a chat.

## Lifecycle

| Action | How | 2FA |
|---|---|---|
| Load | Upload on the Skills page | A code for that load |
| Reload | Reload button | A code for that reload |
| Unload | Unload button | The page unlocked (elevation) |
| Boot load | Registered skills, on container start | None: checksum verified, containment re-judged |

## Persistence

Dynamic skills survive container restarts:

- Source code stored in the database
- Files also stored on the Docker volume
- On boot: files are verified (SHA256) and compiled into the VM
- Tampered files are skipped with an alert

## MCP

Skills are not MCP tools; an MCP client runs workflows, and a dynamic skill is reached by using it as a workflow step.
