# MCP Client Setup

## Prerequisites

1. AlexClaw running with the MCP server started (check `GET /health` — `mcp` should be `"running"`)
2. An MCP key: generated in **Admin > Config**, group **MCP** (see [Authentication](authentication.md)). It is shown once; keep it in the client's config

## Claude Code

Add to your project's `.mcp.json` or global MCP config:

```json
{
  "mcpServers": {
    "alexclaw": {
      "type": "streamable-http",
      "url": "http://localhost:5001/mcp",
      "headers": {
        "Authorization": "Bearer YOUR_API_KEY"
      }
    }
  }
}
```

Then reconnect:

```
/mcp
```

You should see `Reconnected to alexclaw.` and the workflow tools become available.

## Claude Desktop

Add to your Claude Desktop config (`claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "alexclaw": {
      "type": "streamable-http",
      "url": "http://localhost:5001/mcp",
      "headers": {
        "Authorization": "Bearer YOUR_API_KEY"
      }
    }
  }
}
```

Restart Claude Desktop to pick up the changes.

## Cursor

In Cursor settings, add an MCP server with:

- **Type**: Streamable HTTP
- **URL**: `http://localhost:5001/mcp`
- **Headers**: `Authorization: Bearer YOUR_API_KEY`

## Remote Access

If AlexClaw runs on a remote server, replace `localhost:5001` with the server's address. Ensure:

- The MCP endpoint is behind a **reverse proxy with TLS** (HTTPS)
- The port is not directly exposed to the internet
- Example with nginx:

```nginx
location /mcp {
    proxy_pass http://127.0.0.1:5001/mcp;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_read_timeout 600s;  # at least the longest workflow run
}
```

Then use `https://your-domain.com/mcp` as the URL in your client config.

## Verifying the Connection

Once connected, list the tools: each enabled workflow that does not require 2FA appears as `workflow:<name>`. Reading `alexclaw://workflows/list` from the client's resource browser also confirms the connection.

## Troubleshooting

| Problem | Solution |
|---|---|
| "Server unavailable" | Check that AlexClaw container is running and `/health` returns `mcp: running` |
| 401 Unauthorized | The key is not the current one (a newer one was generated, or it was revoked): generate a new key in Admin > Config, group **MCP**, and update the client |
| Connection refused | Check the URL and port — default is `5001` |
| Tools not showing | Only enabled workflows without "Requires 2FA" are tools; reconnect after changing them (`/mcp`), or check container logs for startup errors |
| Tool call times out | MCP waits for the whole run: raise the client's and the proxy's read timeout above the workflow's duration |
