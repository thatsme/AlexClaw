# Reverse Proxy & TLS

In production, AlexClaw should sit behind a reverse proxy with TLS termination.

!!! danger "HTTPS is mandatory"
    The Admin UI uses session cookies and the MCP endpoint uses Bearer tokens. Both are transmitted in plain text over HTTP. Always use HTTPS in production.

## Nginx Example

```nginx
server {
    listen 443 ssl;
    server_name alexclaw.example.com;

    ssl_certificate     /etc/letsencrypt/live/alexclaw.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/alexclaw.example.com/privkey.pem;

    # Web UI + LiveView WebSocket
    location / {
        proxy_pass http://127.0.0.1:5001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # MCP endpoint (longer timeout for tool execution)
    location /mcp {
        proxy_pass http://127.0.0.1:5001/mcp;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_read_timeout 60s;
    }
}

# Redirect HTTP to HTTPS
server {
    listen 80;
    server_name alexclaw.example.com;
    return 301 https://$host$request_uri;
}
```

## Caddy Example

```
alexclaw.example.com {
    reverse_proxy localhost:5001
}
```

Caddy handles TLS automatically via Let's Encrypt.

## Phoenix Configuration

Set `PHX_HOST` in your `.env` to match your domain:

```bash
PHX_HOST=alexclaw.example.com
```

## Ports to Expose

| Port | Expose? | Purpose |
|---|---|---|
| 80/443 | Yes (via proxy) | Web UI + MCP |
| 5001 | No (proxy only) | Application port |
| 5432 | No | PostgreSQL |
| 4369 | No | EPMD (clustering only) |
| 8000 | No | Web automator sidecar |
