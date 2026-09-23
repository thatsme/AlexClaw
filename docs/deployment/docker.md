# Docker Single Node

AlexClaw runs as a Docker Compose stack with four services: the database, a one-shot `migrate` job, the application, and the opt-in web automator.

## Services

| Service | Container Name | Image | Port | Description |
|---|---|---|---|---|
| `alexclaw-prod` | `alexclaw-prod` | Custom (Elixir release) | 5001 | Main application |
| `db-prod` | `alexclaw-db-prod` | PostgreSQL 17 + pgvector | — (internal only) | Database |
| `migrate` | `alexclaw-migrate` | Custom (Elixir release) | — | Applies migrations and exits |
| `web-automator` | — | Custom (Python/Playwright) | 6080 (noVNC, loopback) | Browser automation sidecar, opt-in: `docker compose --profile web-automation up -d` |

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
| `skills_data` | Dynamic skill `.ex` files |
| `backups` | Database backup files (host bind mount) |

## Networks

The stack uses two fixed subnets: `default` (`10.213.61.0/24`), where
`alexclaw-prod` is pinned at `.10` and `migrate` at `.11`, and `automation`
(`10.213.62.0/24`), shared by the app and the web automator. PostgreSQL's
`db-init/pg_hba.conf` accepts network connections only from those two pinned
addresses. To change a subnet, edit `docker-compose.yml`, the pinned addresses
and the two lines of `pg_hba.conf` together, then `docker compose down` before
`docker compose up -d`: a running network keeps its old subnet. The long form
is in [INSTALLATION.md](https://github.com/thatsme/AlexClaw/blob/main/INSTALLATION.md#container-networks).

## Manual Backups

The database accepts no TCP connection from the host, so a manual dump goes
through the container:

```bash
docker compose exec -T db-prod pg_dump -U alexclaw -Fc alex_claw_prod > alex_claw_prod.dump
```

Scheduled backups are the `db_backup` skill (see [Built-in Skills](../skills/builtin.md)).

## Logs

```bash
docker compose logs -f alexclaw-prod       # Follow app logs
docker compose logs --tail=50 alexclaw-prod  # Last 50 lines
```

## Health Check

```bash
curl http://localhost:5001/health
# {"status":"ok","version":"0.3.46+build.414","db":"connected","mcp":"running"}
```

## Environment Variables

Copy `.env.example` to `.env` and configure. See [Environment Variables](../reference/env-vars.md) for the full list.

## Database Migrations

Migrations run in the one-shot `migrate` service, as the database owner. The
application container starts only after it exits successfully, and connects as
a separate application role that cannot change the schema.
