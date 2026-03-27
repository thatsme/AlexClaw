# Security Overview

AlexClaw is a single-user system designed to run on infrastructure you control. Security is layered — each component has independent defenses that don't rely on other layers being intact.

## Attack Surface

| Surface | Protection |
|---|---|
| Web UI (port 5001) | Session auth + rate limiting + 2FA for sensitive ops |
| Telegram bot | Chat ID filtering (single user) |
| Discord bot | Channel ID + guild ID filtering |
| MCP endpoint (`/mcp`) | Bearer token auth + policy engine |
| GitHub webhooks (`/webhooks/github`) | HMAC-SHA256 verification |
| BEAM clustering (port 4369+) | Erlang cookie authentication |
| Dynamic skills | Permission sandbox + integrity verification + 2FA |
| Shell commands | 5-layer defense-in-depth |

## Defense Layers

1. **[Authentication & 2FA](auth.md)** — session-based web auth, TOTP verification for sensitive operations
2. **[Agent Authorization](authorization.md)** — PolicyEngine with capability tokens, chain depth, audit logging
3. **[Dynamic Skill Sandbox](sandbox.md)** — namespace enforcement, permission model, process isolation
4. **[Encryption at Rest](encryption.md)** — AES-256-GCM for API keys and tokens in the database
5. **[MCP Authentication](../mcp/authentication.md)** — Bearer token with constant-time comparison
6. **[MCP Policies](../mcp/policies.md)** — tool-level restriction rules for MCP clients

## Key Principles

- **No hardcoded secrets** — all sensitive values come from environment or encrypted DB
- **Constant-time comparison** — all token/signature checks use `Plug.Crypto.secure_compare/2`
- **Fail closed** — missing config = feature disabled (not open)
- **Audit everything** — authorization decisions are logged with caller, permission, and outcome
- **Let it crash** — OTP supervision handles failures; security checks don't swallow errors
