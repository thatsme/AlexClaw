# MCP Client Setup

## Prerequisites

1. AlexClaw running with the MCP server started (check `GET /health` — `mcp` should be `"running"`)
2. An API key configured: set `mcp.api_key` in **Admin > Config** (see [Authentication](authentication.md))

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

You should see `Reconnected to alexclaw.` and all tools become available.

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
    proxy_read_timeout 60s;
}
```

Then use `https://your-domain.com/mcp` as the URL in your client config.

## Verifying the Connection

Once connected, test with a simple tool call. In Claude Code:

```
> Ask Claude to use the system_info skill
```

You should see the UTC time, hostname, and Elixir version returned from the AlexClaw container.

## Troubleshooting

| Problem | Solution |
|---|---|
| "Server unavailable" | Check that AlexClaw container is running and `/health` returns `mcp: running` |
| 401 Unauthorized | Verify your API key matches `mcp.api_key` in Admin > Config |
| Connection refused | Check the URL and port — default is `5001` |
| Tools not showing | Run `/mcp` to reconnect, or check container logs for startup errors |
| Tool call timeout | Increase `mcp.tool_timeout_ms` in Admin > Config (default 30000ms) |
