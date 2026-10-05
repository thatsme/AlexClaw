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

## Restore drill

`scripts/drill-restore-openbao.sh` proves a snapshot can be restored and
read, and that the unseal key file and the recovery key kept offline are the
right ones, without touching the running OpenBao. It restores the newest
snapshot (or the one named) into a throwaway OpenBao that has no network and
keeps its storage in memory, asks for the recovery key (not echoed), makes a
root token for the restored data with it, reads back every secret the
database's catalogue names — printing names and lengths, never values — and
the transit and TOTP keys, then revokes the token and removes the throwaway.

```bash
scripts/drill-restore-openbao.sh                  # the full drill, at a terminal
scripts/drill-restore-openbao.sh --restore-only   # without the recovery key
```

It ends with `PASS` or `FAIL`. A snapshot that stays sealed means the unseal
key file is not the one the snapshot was taken with; a refused recovery key
means the one kept offline is not this OpenBao's. Either is to be fixed
before the backups are relied on. Run it after the first backup and after
any change to the keys.

## Restoring

- The database: as in [Upgrading to 0.4.0](upgrade-0.4.0.md), "Rolling back"
  (`dropdb`, `createdb`, `pg_restore`), with the 0.4.x release checked out.
- OpenBao: [OpenBao](../architecture/openbao.md#backing-up-and-restoring-openbao),
  "Restoring".
