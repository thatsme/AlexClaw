# Upgrading to 0.3.34 — separate database roles

From 0.3.34 AlexClaw uses two PostgreSQL roles:

| Role | Used by | May |
|---|---|---|
| **Owner** (`DATABASE_OWNER_USERNAME`, e.g. `alexclaw`) | the one-shot `migrate` service, and operator backups and restores | own the schema, run migrations |
| **Application** (`DATABASE_USERNAME`, e.g. `alexclaw_app`) | the running application | read and write the application's tables; **read and insert only** on the audit log |

The application no longer runs migrations. A `migrate` service runs them as the owner, grants the application role its privileges, and exits. The application starts only after that, and it **refuses to start** if its connection is a superuser, can create roles or databases, bypasses row-level security, or owns any table.

Before 0.3.34 there was one role, and it was a superuser. The application could rewrite or delete its own audit log.

A **fresh install** needs nothing from this page: `db-init/01-app-role.sh` creates the application role when the database volume is first initialised. The steps below are for an **existing** installation.

Every command is run from the directory holding `docker-compose.yml` and `.env`. Values in `<angle brackets>` are placeholders.

## Before you start

Take a backup with the owner's credentials. It includes the schema and the audit log:

```bash
mkdir -p ~/backups
docker exec alexclaw-db-prod pg_dump -U <owner> -Fc alex_claw_prod \
  > ~/backups/alex_claw_prod-$(date +%Y%m%d-%H%M%S).dump
```

`<owner>` is the current `DATABASE_USERNAME` from `.env`, usually `alexclaw`.

## 1. Create the application role

Do this once, as the current owner. Generate a new password; it must not be the owner's:

```bash
openssl rand -hex 32
```

Paste it where the SQL below says `<application password>`. Hex digits need no escaping in the SQL string, but a password containing a single quote would.

```bash
docker exec -i alexclaw-db-prod psql -U <owner> -d alex_claw_prod <<'SQL'
CREATE ROLE alexclaw_app LOGIN PASSWORD '<application password>'
  NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
GRANT CONNECT ON DATABASE alex_claw_prod TO alexclaw_app;
GRANT USAGE ON SCHEMA public TO alexclaw_app;
SQL
```

The table privileges are not granted here. The `migrate` service grants them on every deploy, so a table added by a later release is covered too.

## 2. Split the credentials in `.env`

Replace the two database lines with four:

```bash
DATABASE_OWNER_USERNAME=<owner>
DATABASE_OWNER_PASSWORD=<the current DATABASE_PASSWORD>
DATABASE_USERNAME=alexclaw_app
DATABASE_PASSWORD=<application password>
```

The owner's credentials reach only the `migrate` service and the database container. The application container never sees them.

## 3. Deploy 0.3.34

Get the 0.3.34 code, then build and start:

```bash
git fetch --tags
git checkout v0.3.34
docker compose up -d --build
```

The `migrate` service runs first, migrates and grants, then exits. The application starts after it and connects as `alexclaw_app`. To follow the migrate step:

```bash
docker logs alexclaw-migrate
# ... Granted alexclaw_app the application's privileges.
```

## 4. Verify

The live connection is not a superuser:

```bash
docker exec alexclaw-db-prod psql -U <owner> -d alex_claw_prod -c \
  "SELECT DISTINCT usename, usesuper FROM pg_stat_activity
   JOIN pg_user USING (usename) WHERE datname = 'alex_claw_prod';"
# alexclaw_app | f   (and the owner's own row for this query)
```

The audit log cannot be deleted from as the application:

```bash
docker exec -e PGPASSWORD='<application password>' alexclaw-db-prod \
  psql -h localhost -U alexclaw_app -d alex_claw_prod -c "DELETE FROM auth_audit_log WHERE false;"
# ERROR:  permission denied for table auth_audit_log
```

## If the application does not start

If the log says `AlexClaw will not start on this database connection`, then `DATABASE_USERNAME` is still the owner. Step 2 was not applied, or the containers were not recreated. The message lists every privilege the connection should not have.

## Rolling back

Stop the stack, restore `.env` to its single-role values, and deploy 0.3.33:

```bash
docker compose stop
git checkout v0.3.33
docker compose up -d --build
```

The `alexclaw_app` role and its privileges do nothing unless `.env` names it. Dropping the role is optional.

**Upgrading again after a rollback:** skip step 1, since the role already exists and `CREATE ROLE` would fail with `role "alexclaw_app" already exists`. Start from step 2.

## Restoring after 0.3.34

- **From the admin UI.** Database → **Export Data** writes the application's data as a JSON file, and **Restore** loads such a file. The restore replaces the application's data. It never touches the audit log or the current sign-ins, and it never runs anything from the file. Each restore asks for a code. Encrypted values (sensitive settings, and from 0.3.35 every stored credential) are written to the file encrypted under `SECRET_KEY_BASE`, so a file restores only on an installation with the same key.
- **A full restore**, schema and audit log included, is an operator step with the owner's credentials. It **replaces the whole database** with the backup: take a fresh backup first if the current data may still be needed.

  The backup can come from **Download Backup** (`.sql`), the backup skill (`.sql.gz`), or the command in *Before you start* (`.dump`). The database is recreated first, so the restore reproduces the backup exactly whatever version it was made on. `migrate` then brings the schema up to date and grants the application role its privileges:

  ```bash
  docker compose stop alexclaw-prod
  docker exec alexclaw-db-prod dropdb -U <owner> alex_claw_prod
  docker exec alexclaw-db-prod createdb -U <owner> alex_claw_prod

  # a .dump (pg_dump -Fc)
  docker exec -i alexclaw-db-prod pg_restore -U <owner> -d alex_claw_prod < backup.dump
  # or a .sql
  docker exec -i alexclaw-db-prod psql -U <owner> -d alex_claw_prod --single-transaction -v ON_ERROR_STOP=1 < backup.sql
  # or a .sql.gz
  gunzip -c backup.sql.gz | docker exec -i alexclaw-db-prod \
    psql -U <owner> -d alex_claw_prod --single-transaction -v ON_ERROR_STOP=1

  docker compose run --rm migrate
  docker compose up -d
  ```

  Restoring over the existing database with `pg_restore --clean` is not enough for a backup made on an older version. It removes only the objects the backup contains, so tables added since stay behind, and `migrate` then fails when it tries to create them again.

## Multi-node (`docker-compose_swarm.yml`)

The same steps apply. The swarm file has the same `migrate` service, and both nodes wait for it and connect as the application role.

## What the upgrade was tested on

The steps above were rehearsed from 0.3.29 on a copy of a production database, with the single-node `docker-compose.yml`: the upgrade, both checks in step 4, the rollback to 0.3.33, upgrading again after it, and the full restore of a backup from before the upgrade. On the upgraded copy, the admin UI's Export Data and Restore were run as a round trip with a two-factor code, and `SECRET_KEY_BASE` was rotated with [its procedure](rotate-secret-key-base.md); afterwards the settings and the TOTP secret decrypted under the new key, and an export made under the old one was refused.

Not rehearsed:

- **Multi-node**, with `docker-compose_swarm.yml`.
- **The web-automator service.** The upgrade does not change it, but it was not running during the rehearsal.
