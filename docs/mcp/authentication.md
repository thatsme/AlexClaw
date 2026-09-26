# MCP Authentication

The MCP endpoint uses Bearer token authentication — every request must include a valid key in the `Authorization` header. The security model is described in [SECURITY.md](https://github.com/thatsme/AlexClaw/blob/main/SECURITY.md#mcp-server-authentication).

## Setup

1. Navigate to **Admin > Config** and open the **MCP** group
2. Click **Generate** (the admin second factor is required)
3. Copy the key shown: it is displayed once and cannot be shown again

!!! warning "No key = no access"
    While no key is configured, the auth plug rejects **all** MCP requests with 401. This is by design — MCP is disabled until a key is generated.

## How It Works

AlexClaw never stores the key. It keeps a fingerprint: an HMAC of the key computed by OpenBao's transit engine, with a key AlexClaw never holds (`AlexClaw.MCP.Key`).

The `AlexClawWeb.Plugs.McpAuth` plug:

1. Reads the `Authorization: Bearer <token>` header
2. Has OpenBao compute the HMAC of the token (`AlexClaw.MCP.Key.valid?/1`)
3. Compares it with the stored fingerprint using `Plug.Crypto.secure_compare/2` (constant time)
4. Returns a 401 JSON error if they differ

## Error Responses

All auth failures return HTTP 401 with a JSON body:

| Scenario | Response |
|---|---|
| Missing `Authorization` header | `{"error": "Missing Authorization header"}` |
| Invalid token | `{"error": "Invalid API key"}` |
| Key not configured | `{"error": "MCP API key not configured"}` |
| Non-Bearer scheme | `{"error": "Missing Authorization header"}` |

## Key Management

- **Storage** — only the fingerprint is stored (the `mcp.api_key` setting). A copy of the database holds nothing that can be turned back into the key or tried offline
- **No expiration** — the key is long-lived; treat it like an API key
- **Rotation** — **Generate** again: the new key replaces the old one at once
- **Revocation** — **Revoke** leaves no key; MCP refuses every request until a new one is generated
- **Upgrading from 0.3.x** — an existing key keeps working: at the first start its fingerprint replaces it

## Hardening

!!! danger "Always use HTTPS"
    Bearer tokens are sent in plain text in the HTTP header. Never expose the `/mcp` endpoint over plain HTTP in production. Use a reverse proxy with TLS termination.

- Store the key in the client's config securely (environment variable or encrypted config)
- Monitor the Audit Log for unexpected MCP activity
- Generate a new key regularly
