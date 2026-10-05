# Backups

AlexClaw's state is in two places, and a backup is both of them:

- the **database** — settings, workflows, runs, memory, the secret catalogue
  (names and bindings, never values);
- **OpenBao** — every credential's value
  ([OpenBao](../architecture/openbao.md)).

A database backup without the OpenBao snapshot from the same moment restores
records whose credentials are gone; a snapshot without the database restores
credentials nothing refers to.

## The nightly backup

`scripts/backup-scheduled.sh` takes both, one after the other, into
`~/backups` (`SCHEDULED_BACKUP_DIR` to change it):

| File | What | Checked by |
|---|---|---|
| `alex_claw_prod-<timestamp>-scheduled.dump` | `pg_dump -Fc` of the database, as its owner | `pg_restore --list` reading it back |
| `openbao-<timestamp>-scheduled.snap` | an OpenBao raft snapshot (`make backup-openbao`) | its archive's `SHA256SUMS` |

Every file, and the log `scheduled-backup.log`, is readable by its owner only.
The newest 14 of each kind are kept (`SCHEDULED_BACKUP_KEEP`); older files
with the `-scheduled` suffix are deleted. Backups taken by hand — with any
other name — are never deleted by it. A failure is written to the log and
shown as a macOS notification; the backups already there stay.

On macOS it runs every night at 03:30 as a LaunchAgent of the user who runs
AlexClaw; a Mac asleep at that time runs it when it next wakes:

```bash
scripts/launchd/install.sh          # install, or reinstall after moving the checkout
scripts/launchd/install.sh remove   # remove
launchctl kickstart gui/$(id -u)/com.alexclaw.backup   # run it now
```

It needs Docker running, and runs from the checkout it was installed from:
moving or deleting that checkout stops it.

## What a backup does not hold

The OpenBao snapshot is encrypted with the unseal key and does **not** hold
it: without `OPENBAO_UNSEAL_DIR/key` — and, to make a root token, the
recovery key — no snapshot can be opened. Both are kept offline, apart from
the backups. Losing the unseal key loses every credential, every snapshot
included.

The backups are on the same machine as AlexClaw. A copy elsewhere (another
disk, another machine) is what survives losing the machine.

## Restoring

- The database: as in [Upgrading to 0.4.0](upgrade-0.4.0.md), "Rolling back"
  (`dropdb`, `createdb`, `pg_restore`), with the 0.4.x release checked out.
- OpenBao: [OpenBao](../architecture/openbao.md#backing-up-and-restoring-openbao),
  "Restoring".
