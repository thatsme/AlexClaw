# MCP Authentication

The MCP endpoint uses Bearer token authentication — every request must include a valid token in the `Authorization` header.

## Setup

1. Navigate to **Admin > Config**
2. Set `mcp.api_key` to a strong random value:

    ```bash
    # Generate a secure key
    openssl rand -base64 32
    ```

3. Category: `mcp`, Type: `string`, Sensitive: `true`

!!! warning "No key = no access"
    If `mcp.api_key` is not set or is empty, the auth plug rejects **all** MCP requests with 401. This is by design — MCP is disabled until you explicitly configure a key.

## How It Works

The `AlexClawWeb.Plugs.McpAuth` plug:

1. Reads the `Authorization: Bearer <token>` header
2. Loads the expected key from `AlexClaw.Config.get("mcp.api_key")`
3. Compares using `Plug.Crypto.secure_compare/2` (constant-time, no timing attacks)
4. Returns 401 JSON error if validation fails

```elixir
# The comparison is timing-safe
Plug.Crypto.secure_compare(token, expected_key)
```

## Error Responses

All auth failures return HTTP 401 with a JSON body:

| Scenario | Response |
|---|---|
| Missing `Authorization` header | `{"error": "Missing Authorization header"}` |
| Invalid token | `{"error": "Invalid API key"}` |
| Key not configured | `{"error": "MCP API key not configured"}` |
| Non-Bearer scheme | `{"error": "Missing Authorization header"}` |

## Token Management

- **Storage** — the key is AES-256-GCM encrypted at rest in PostgreSQL (marked `sensitive: true`)
- **No expiration** — tokens are long-lived, treat them like API keys
- **Rotation** — update `mcp.api_key` in Admin > Config to immediately invalidate all previous tokens
- **Compromise** — if a token is leaked, rotate immediately in Admin > Config

## Hardening

!!! danger "Always use HTTPS"
    Bearer tokens are sent in plain text in the HTTP header. Never expose the `/mcp` endpoint over plain HTTP in production. Use a reverse proxy with TLS termination.

- Store the API key in your client's config securely (environment variable or encrypted config)
- Monitor the Audit Log for unexpected MCP activity
- Rotate `mcp.api_key` regularly
