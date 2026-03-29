# Docker Single Node

AlexClaw runs as a Docker Compose stack with three services.

## Services

| Service | Container Name | Image | Port | Description |
|---|---|---|---|---|
| `alexclaw-prod` | `alexclaw-prod` | Custom (Elixir release) | 5001 | Main application |
| `db-prod` | `alexclaw-db-prod` | PostgreSQL 17 + pgvector | 5432 | Database |
| `web-automator` | — | Custom (Python/Playwright) | 8000 | Browser automation sidecar (optional) |

## Starting

```bash
docker compose up -d
```

## Rebuilding

After code changes, rebuild only the app container:

```bash
docker compose up --build --no-deps -d alexclaw-prod
```

!!! warning "Always use `--no-deps`"
    This prevents recreating the database container and losing data.

## Stopping

```bash
docker compose down        # Stop containers (data preserved in volumes)
```

!!! danger "Never use `-v` flag"
    `docker compose down -v` destroys volumes including the database. All data will be lost.

## Volumes

| Volume | Purpose |
|---|---|
| `pgdata` | PostgreSQL data directory |
| `skills` | Dynamic skill `.ex` files |
| `backups` | Database backup files (host bind mount) |

## Logs

```bash
docker compose logs -f alexclaw-prod       # Follow app logs
docker compose logs --tail=50 alexclaw-prod  # Last 50 lines
```

## Health Check

```bash
curl http://localhost:5001/health
# {"status":"ok","version":"0.3.13","db":"connected","mcp":"running"}
```

## Environment Variables

Copy `.env.example` to `.env` and configure. See [Environment Variables](../reference/env-vars.md) for the full list.

## Database Migrations

Migrations run automatically on container start via the release entrypoint. No manual `mix ecto.migrate` needed.
