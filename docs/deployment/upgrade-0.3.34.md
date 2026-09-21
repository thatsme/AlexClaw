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
docker exec alexclaw-db-prod pg_dump -U <owner> -Fc alex_claw_prod \
  > ~/backups/alex_claw_prod-$(date +%Y%m%d-%H%M%S).dump
```

`<owner>` is the current `DATABASE_USERNAME` from `.env`, usually `alexclaw`.

## 1. Create the application role

Do this once, as the current owner. Choose a new password; it must not be the owner's.

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

```bash
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

Stop the stack, restore `.env` to its single-role values, and deploy 0.3.33. The `alexclaw_app` role and its privileges do nothing unless `.env` names it. Dropping the role is optional.

## Restoring after 0.3.34

- **From the admin UI.** Database → **Export Data** writes the application's data as a JSON file, and **Restore** loads such a file. The restore replaces the application's data. It never touches the audit log or the current sign-ins, and it never runs anything from the file. Each restore asks for a code.
- **A full restore**, schema and audit log included, is an operator step with the owner's credentials. Use it with a backup from **Download Backup**, the backup skill, or the command in *Before you start*:

  ```bash
  # a .dump from pg_dump -Fc
  docker exec -i alexclaw-db-prod pg_restore -U <owner> -d alex_claw_prod --clean --if-exists < backup.dump

  # a .sql or .sql.gz from Download Backup or the backup skill
  gunzip -c backup.sql.gz | docker exec -i alexclaw-db-prod \
    psql -U <owner> -d alex_claw_prod --single-transaction
  ```

  Then restart the stack, so that the `migrate` service grants the application role its privileges again.

## Multi-node (`docker-compose_swarm.yml`)

The same steps apply. The swarm file has the same `migrate` service, and both nodes wait for it and connect as the application role.
