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

Loading or reloading an uploaded skill needs a code typed on the Skills page;
unloading needs an elevation. A generated skill that stays within the contained
set and the unattended permission ceiling loads without a code.

### 7. External Skill Detection (AST-Based)

Skills that fetch external data must declare `def external, do: true`. At load time, the registry AST-scans the source for calls to HTTP/socket libraries:

- `Req.get/post/put/delete/request`
- `HTTPoison.get/post/request`
- `Finch.request/build`
- `Tesla.get/post/request`
- `:gen_tcp.connect`, `:gen_udp.open`, `:httpc.request`
- `SkillAPI.http_get/http_post/http_request`

If any are detected without `external/0`, the skill is **rejected** (fail-closed). This prevents untagged dynamic skills from ingesting external data without the `ContentSanitizer` defense layer.

!!! warning "Single-module limitation"
    The AST scan only inspects the skill module itself. Indirect calls through helper modules that wrap HTTP clients are not detected in v1. Future: integration with Giulia's coupling graph for transitive call analysis.

## What Dynamic Skills Cannot Do

| Action | Blocked By |
|---|---|
| Access the database directly | No `Repo` access through SkillAPI |
| Call arbitrary Elixir modules | Containment: every direct call must resolve to the allowlist, checked at load and on every boot |
| Modify other skills | SkillAPI has no function that writes or loads a skill |
| Modify or start workflows | SkillAPI has no function that creates, changes or starts a workflow |
| Execute shell commands | `SkillAPI.run_skill/3` refuses `shell`, `coder`, `db_backup` and `web_automation` for every caller |
| Escalate permissions | Capability token is scoped at mint time |

!!! note "BEAM limitation"
    The BEAM VM does not provide true sandboxing. Containment is a static check of the calls a skill's source names, and the permission system decides what `SkillAPI` does on a skill's behalf: together a trust boundary, not a hard sandbox. This is acceptable for a single-user system where the operator controls what code is loaded.

## Monitoring

- All permission checks are logged to the audit log
- Circuit breakers track failure rates per skill
- The Admin UI shows skill status, permissions, and load history
