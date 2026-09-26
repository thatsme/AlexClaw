# Docker Single Node

AlexClaw runs as a Docker Compose stack: the database, a one-shot `migrate` job, the application, OpenBao with its one-shot `openbao-init`, the one-shot `automator-token-init`, the opt-in web automator, and the on-demand `openbao-backup`.

## Services

| Service | Container Name | Image | Port | Description |
|---|---|---|---|---|
| `alexclaw-prod` | `alexclaw-prod` | Custom (Elixir release) | 5001 | Main application |
| `db-prod` | `alexclaw-db-prod` | PostgreSQL 17 + pgvector | — (internal only) | Database |
| `migrate` | `alexclaw-migrate` | Custom (Elixir release) | — | Applies migrations and exits |
| `web-automator` | — | Custom (Python/Playwright) | 6080 (noVNC, loopback) | Browser automation sidecar, opt-in: `docker compose --profile web-automation up -d` |
| `openbao` | — | OpenBao 2.6, pinned by digest | — (never published) | Holds every secret |
| `openbao-init` | — | Custom (`openbao/init.Dockerfile`) | — | Makes OpenBao's TLS certificate at every start; initialises OpenBao once, at a terminal |
| `automator-token-init` | — | Custom (Elixir release image) | — | Generates the web automator's token once, and exits |
| `openbao-backup` | — | Custom (`openbao/init.Dockerfile`) | — | Takes an OpenBao snapshot, on demand only (compose profile `backup`, run by `make backup-openbao`) |

## Starting

```bash
docker compose up -d
```

The first start also needs OpenBao's unseal key and a one-time
initialisation at a terminal: see [OpenBao](../architecture/openbao.md#first-start).

## Rebuilding

After code changes, rebuild and start the stack:

```bash
docker compose up --build -d
```

The `migrate` job runs first, and the application starts after it. Volumes
are kept; only `docker compose down -v` removes them.

## Stopping

```bash
docker compose down        # Stop containers (data preserved in volumes)
```

!!! danger "Never use `-v` flag"
    `docker compose down -v` destroys the volumes: the database and OpenBao's data, so every stored credential too. All data will be lost.

## Volumes

| Volume | Purpose |
|---|---|
| `pgdata` | PostgreSQL data directory |
| `skills_data` | Dynamic skill `.ex` files |
| `backups` | Database backup files (host bind mount, `BACKUP_DIR`) |
| `openbao_data` | OpenBao's storage and audit log — every secret |
| `openbao_tls` | OpenBao's server certificate and key |
| `openbao_bootstrap` | AlexClaw's AppRole credentials and OpenBao's CA certificate |
| `openbao_backup` | The backup AppRole's credentials; mounted by `openbao-init` and `openbao-backup` only |
| `automator_token` | The token AlexClaw and the web automator share |
| `./openbao/unseal` | OpenBao's unseal key (host bind mount, `OPENBAO_UNSEAL_DIR`) |

## Networks

The stack uses three fixed subnets: `default` (`10.213.61.0/24`), where
`alexclaw-prod` is pinned at `.10` and `migrate` at `.11`; `automation`
(`10.213.62.0/24`), shared by the app and the web automator; and `vault`
(`10.213.63.0/24`, internal), where OpenBao is at `.2`, `alexclaw-prod` at
`.10` — the address OpenBao's AppRole accepts — and `openbao-backup` at `.11`
(see [OpenBao](../architecture/openbao.md)). PostgreSQL's
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
