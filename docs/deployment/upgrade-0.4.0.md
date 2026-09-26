# Upgrading to 0.4.0 — credentials in OpenBao

From 0.4.0 AlexClaw keeps every credential in OpenBao, which runs as its own
container beside it. The first start of 0.4.0 that can reach OpenBao moves
every credential 0.3.x held — settings, LLM providers, workflow steps,
resources, recordings, the second factor — into OpenBao: each value is stored,
read back and compared before its database copy is emptied, and nothing has to
be entered again.

This page is the upgrade procedure. It was rehearsed end to end on a copy of a
0.3.55 installation holding a second factor, recovery codes, secret settings,
an LLM provider, an API resource and workflow steps with credentials —
rollback included.

Every command runs from the directory holding `docker-compose.yml` and `.env`.
`<owner>` is the database owner (`DATABASE_OWNER_USERNAME`, usually
`alexclaw`).

## Before starting

- **Upgrade from 0.3.55**, and let the first start of 0.4.0 finish before
  installing a later release: the code that reads 0.3.x values is planned for
  removal after 0.4.0.
- **Take a database backup** with the owner's credentials, and check it:

  ```bash
  mkdir -p ~/backups
  docker exec alexclaw-db-prod pg_dump -U <owner> -Fc alex_claw_prod \
    > ~/backups/alex_claw_prod-pre-0.4.0.dump
  docker exec -i alexclaw-db-prod pg_restore --list < ~/backups/alex_claw_prod-pre-0.4.0.dump > /dev/null
  ```

  Copy `.env` beside it. This backup is the way back ("Rolling back" below):
  0.4.0 refuses to restore an export that holds values 0.3.x encrypted.
- **Keep `SECRET_KEY_BASE` unchanged** until the upgrade is confirmed (step
  5): the first start reads what 0.3.x encrypted under it, and a value that
  did not move is retried at the next start with the same key.

## 1. Get the code and make OpenBao's unseal key

```bash
git fetch --tags && git checkout v0.4.0
mkdir -p openbao/unseal
head -c 32 /dev/urandom > openbao/unseal/key
chmod 0440 openbao/unseal/key          # on Linux also: sudo chown 100 openbao/unseal/key
```

OpenBao encrypts all its data with this file: **losing it loses every
credential AlexClaw holds**, with no recovery. Keep a copy offline. The
directory can be moved with `OPENBAO_UNSEAL_DIR`.

## 2. Build and start

```bash
docker compose up -d --build
```

A `pull access denied` line for the application image before it is built is
Compose trying a registry first; the build follows. `migrate` runs the new
migrations. `openbao-init` makes OpenBao's certificate and stops, saying OpenBao
is not initialised. AlexClaw starts and moves nothing yet: every value stays in
the database, and the log repeats that OpenBao cannot be logged in to until
step 3.

## 3. Initialise OpenBao, once, at a terminal

```bash
docker compose run --rm openbao-init
```

It prints the **recovery key** once and names the unseal key file, then waits
until `SAVED` is typed: store the recovery key and the unseal key file offline
first. It then enables OpenBao's engines, writes AlexClaw's policy, creates the
AppRole AlexClaw logs in with (accepted only from AlexClaw's address), creates
the backup's own AppRole (it may take a snapshot and nothing else), and revokes
the root token. The recovery key is needed later only for the procedures in
[OpenBao](../architecture/openbao.md).

## 4. Start AlexClaw again

```bash
docker compose restart alexclaw-prod
docker compose logs alexclaw-prod | grep -iE "openbao|moved|parked|second factor"
```

This start moves the credentials:

- **Moved:** the secret settings; every header of an API Request step and a
  Telegram Notify step's own bot token; a resource's credential; every fill
  value of a recording and of a Web Automation step's recipe; an LLM
  provider's key and headers. The rows keep references to OpenBao. Values are
  carried exactly, surrounding whitespace included.
- **Converted:** the MCP key becomes its HMAC (a configured client keeps
  working; the key can no longer be shown). The authenticator key moves into
  OpenBao: the phone's entry keeps working. Recovery codes keep working.
- **Parked** (stored in OpenBao, sent nowhere, named in the log): a setting the
  admin had added and marked sensitive, and any other encrypted value in a
  step's config that the step's skill does not declare.
- **Left as it was, and named in the log:** a value OpenBao already holds a
  different one for, a credential that is a list or an object, and the headers
  of an API Request step addressed through an API resource when its workflow
  has none. A failure leaves the database copy untouched and is retried at the
  next start.

## 5. Confirm the upgrade

- `docker compose ps -a`: `openbao` running; `migrate` and
  `automator-token-init` exited 0.
- The log from step 4 has `Moved to OpenBao: …` and
  `Credentials moved to OpenBao: …` lines, and none of `NOT moved to OpenBao`,
  `The second factor was NOT carried over` or `OpenBao login failed`.
- The Config page shows each secret setting as set, never its value.
- Sign in, and unlock editing with a code from the existing authenticator
  entry.
- `docker compose restart alexclaw-prod` once more: no `NOT moved` line.
- **Back up OpenBao now:** `make backup-openbao REASON=after-0.4.0`
  ([OpenBao](../architecture/openbao.md#backing-up-and-restoring-openbao)). From
  here on, back it up beside every database backup.

## 6. After the upgrade

- **Set the gateway owners, or the bots answer nothing.**
  `telegram.owner_user_id` and `discord.owner_user_id` start blank; set them
  on the Config page (a configuration change needs editing unlocked with a
  code; an installation without a second factor sets one up first, on the
  Services page). A message is answered only when it comes from that user in
  the owner chat.
- **Declare or delete what was parked**, by the names in the log.
- **Privileged workflows.** A workflow with a `shell`, `coder`, `db_backup` or
  `web_automation` step — as a step or as a step's fallback — runs from its
  schedule, or from the admin UI with a code. It is refused before it starts
  from a chat, MCP, a webhook or another node.
- **Dynamic skills.** Every dynamic skill must stay inside the contained set,
  whoever approved it: no import (write calls in full; `require Logger` is
  allowed), nothing outside the allowed modules. A skill that fetches through
  `SkillAPI.http_get`, `http_post` or `http_request` declares
  `def external, do: true`, aliased calls included, so its output is
  sanitised. Every dynamic skill is checked again at the first start; one that
  fails is not loaded, and the log names it and the calls. XML is read with
  `SkillAPI.parse_xml/2`; a skill attaches its own secret only through
  `:secret_headers`.
- **Credentials are bound to a host.** Changing the host of a step, resource
  or provider needs its credential entered again. An API Request step
  addressed through its workflow's API resource has its headers bound to that
  resource's host.
- **Reasoning whitelist.** An existing `reasoning.skill_whitelist` keeps
  `google_tasks` until it is removed on the Config page.
- **Cluster.** A `receive_from_workflow` gate with no `allowed_nodes` allows
  no node, and a node is registered on the Cluster page, not by connecting.
- **Admin password.** The first login stores its hash, and `ADMIN_PASSWORD` is
  ignored from then on.
- **`.env`.** Delete the variables 0.4.0 no longer reads: they hold live
  credentials in plain text. The release notes list them.
- **Rotate what 0.3.x held, and retire old backups.** Backups, exports and the
  old `.env` still hold every credential. Once the upgrade is confirmed,
  rotate each third-party credential at its provider, enter the new values,
  and archive or delete the old backups. `SECRET_KEY_BASE` may then be
  changed: that ends every login and makes no stored value unreadable.
- **A lost second factor.** With the authenticator and every recovery code
  lost, `make reset-2fa` on the host turns the second factor off (the security
  policy, "If everything is lost").

## Rolling back

The backup taken before step 2 holds every credential as 0.3.x kept it. Check
out 0.3.x **first**: the restore ends by migrating the database, and 0.4.0's
migrations would upgrade it again.

```bash
docker compose stop alexclaw-prod
git checkout v0.3.55
docker exec alexclaw-db-prod dropdb -U <owner> alex_claw_prod
docker exec alexclaw-db-prod createdb -U <owner> alex_claw_prod
docker exec -i alexclaw-db-prod pg_restore -U <owner> -d alex_claw_prod < ~/backups/alex_claw_prod-pre-0.4.0.dump
docker compose run --rm migrate
docker compose up -d --build
```

0.3.55 then runs on its own data, second factor and recovery codes included;
anything entered after the upgrade is not in that backup.

OpenBao keeps running beside it with the values the upgrade stored; 0.3.x does
not use it.

**Before upgrading again after a rollback, start OpenBao fresh.** Otherwise
the upgrade finds OpenBao already holding the values stored the first time,
keeps those older values, and logs a conflict for every credential changed
since (step 4, "Left as it was"). Take the backup in "Before starting"
again, do step 1 (the existing unseal key file can be kept), then remove
OpenBao and its three volumes before step 2, and run step 3 again, so the
current 0.3.x values are the ones moved:

```bash
docker compose rm -sf openbao openbao-init
docker volume rm <project>_openbao_data <project>_openbao_tls <project>_openbao_bootstrap
```

`<project>` is the Compose project name, by default the deployment
directory's name in lower case; `docker volume ls` lists them. This deletes
every value the first upgrade stored in OpenBao, and the recovery key printed
the first time no longer applies: store the new one step 3 prints.
