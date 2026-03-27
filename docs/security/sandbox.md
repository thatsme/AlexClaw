# Dynamic Skill Sandbox

Dynamic skills run in a sandboxed environment with multiple layers of protection.

## Security Layers

### 1. Namespace Enforcement

All dynamic skills must be in `AlexClaw.Skills.Dynamic.*`. Modules in other namespaces are rejected at load time.

### 2. Permission Declaration

Skills declare required permissions via `permissions/0`. The PolicyEngine denies any undeclared permission at runtime:

```elixir
# This skill can only read the web and call LLMs
def permissions, do: [:web_read, :llm]

# Attempting to store memory without declaring :memory_write → denied
```

### 3. Capability Tokens

Each skill execution gets a scoped HMAC-signed token containing only its declared permissions. Cross-skill calls further attenuate the token — a skill cannot escalate its own privileges.

### 4. Process Isolation

Dynamic skills execute in spawned processes via `SafeExecutor`. Auth state (capability token, chain depth) is isolated in the process dictionary — it cannot leak to or from the caller.

### 5. Integrity Verification

On load, a SHA256 checksum of the source code is computed and stored. On boot, files are re-verified against the stored checksum. Tampered files are skipped with a Telegram alert.

### 6. 2FA Gate

Every skill management operation (load, unload, reload) requires TOTP verification sent to Telegram/Discord. No exceptions.

## What Dynamic Skills Cannot Do

| Action | Blocked By |
|---|---|
| Access the database directly | No `Repo` access through SkillAPI |
| Call arbitrary Elixir modules | Convention, not enforcement (BEAM limitation) |
| Modify other skills | Requires `:skill_manage` permission |
| Modify workflows | Requires `:workflow_manage` permission |
| Execute shell commands | Requires `:shell` permission + 2FA |
| Escalate permissions | Capability token is scoped at mint time |

!!! note "BEAM limitation"
    The BEAM VM does not provide true sandboxing — a determined module could call any function. The permission system is a trust boundary, not a hard sandbox. This is acceptable for a single-user system where the operator controls what code is loaded.

## Monitoring

- All permission checks are logged to the audit log
- Circuit breakers track failure rates per skill
- The Admin UI shows skill status, permissions, and load history
