# VPS Hardening

Checklist for running AlexClaw on a virtual private server.

## Firewall

Only expose what's needed:

```bash
# Allow SSH, HTTP, HTTPS
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw enable

# Everything else is blocked by default
# Do NOT expose 5001, 5432, 4369, 6080
```

## Docker Security

- Run containers as non-root (AlexClaw's Dockerfile already does this)
- Don't mount the Docker socket into containers
- Use Docker's built-in network isolation
- Keep Docker and images updated

## Secrets Management

- Use `.env` file with `chmod 600` permissions
- Never commit `.env` to version control
- Generate strong secrets:

```bash
# SECRET_KEY_BASE
openssl rand -base64 64

# DATABASE_PASSWORD
openssl rand -base64 32

# CLUSTER_COOKIE
openssl rand -base64 32
```

The MCP key is not generated here: AlexClaw generates it on the Config page (group **MCP**) and shows it once.

- OpenBao's unseal key (`openbao/unseal/key`, or `OPENBAO_UNSEAL_DIR`) and
  the recovery key printed at initialisation: keep both offline, apart from
  the server's backups. Losing the unseal key loses every stored credential.

## Backups

Configure automated database backups:

1. Set `BACKUP_DIR` to a path outside the Docker data directory
2. Create a workflow: `db_backup` → `telegram_notify`
3. Schedule it via cron (e.g., daily at 03:00)
4. Enable in Admin > Config: `backup.enabled = true`
5. Back up OpenBao's data together with the database — the database holds
   only references to the credentials: `make backup-openbao REASON=<reason>`
   writes a snapshot to `OPENBAO_BACKUP_DIR`, which must be outside
   `BACKUP_DIR` (AlexClaw mounts that directory)
   (see [OpenBao](../architecture/openbao.md#backing-up-and-restoring-openbao))

Also consider:

- Periodic off-site backup copies (rsync, S3, etc.)
- Test restore procedures regularly

## Monitoring

- `/health` endpoint for uptime monitoring (supports any HTTP checker)
- `/metrics` endpoint for detailed system stats (authenticated)
- Telegram notifications for circuit breaker events and workflow failures
- Docker healthcheck is built into the Dockerfile

## Updates

```bash
cd AlexClaw
git pull
docker compose up --build -d
```

Migrations run in the one-shot `migrate` job before the application starts.
Upgrading from 0.3.x needs OpenBao set up first: see
[OpenBao](../architecture/openbao.md#first-start).
