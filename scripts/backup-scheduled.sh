#!/bin/sh
# The scheduled backup: the database and OpenBao, together — a database
# backup without its OpenBao snapshot restores records whose credentials are
# gone. Run nightly by the LaunchAgent in scripts/launchd/ (see
# docs/deployment/backups.md); safe to run by hand.
#
#   scripts/backup-scheduled.sh
#
# Writes, into $SCHEDULED_BACKUP_DIR (default ~/backups), readable by the
# owner only and each checked before it counts:
#   alex_claw_prod-<timestamp>-scheduled.dump   (pg_dump -Fc, then pg_restore --list)
#   openbao-<timestamp>-scheduled.snap          (scripts/backup-openbao.sh, checksums)
# Keeps the newest $SCHEDULED_BACKUP_KEEP (default 14) of each, and deletes
# only older files with the -scheduled suffix: backups taken by hand are
# never touched. A failure is logged, shown as a notification, and leaves
# the backups already there in place.
set -eu

cd "$(dirname "$0")/.." || exit 1

# launchd starts with a bare PATH: docker (OrbStack) and the shell tools.
PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export PATH

dir="${SCHEDULED_BACKUP_DIR:-$HOME/backups}"
keep="${SCHEDULED_BACKUP_KEEP:-14}"
log="$dir/scheduled-backup.log"
stamp=$(date +%Y%m%d-%H%M%S)

# Everything this writes — dumps, snapshots, the log — is the owner's only.
umask 077
mkdir -p "$dir"
chmod 700 "$dir"
touch "$log"
chmod 600 "$log"

say() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$log"; }

failed() {
  say "FAILED: $1"
  osascript -e "display notification \"$1\" with title \"AlexClaw backup failed\"" 2>/dev/null || true
  exit 1
}

say "start"

docker info >/dev/null 2>&1 || failed "Docker (OrbStack) is not running"

# The database owner, read from .env without printing anything else of it.
owner=$(sed -n 's/^DATABASE_OWNER_USERNAME=//p' .env | tail -1 | tr -d "\"' \r")
[ -n "$owner" ] || failed "DATABASE_OWNER_USERNAME is not set in .env"

dump="$dir/alex_claw_prod-${stamp}-scheduled.dump"
docker exec alexclaw-db-prod pg_dump -U "$owner" -Fc alex_claw_prod >"$dump" ||
  { rm -f "$dump"; failed "pg_dump failed"; }
docker exec -i alexclaw-db-prod pg_restore --list <"$dump" >/dev/null ||
  { rm -f "$dump"; failed "the database dump does not read back (pg_restore --list)"; }
chmod 600 "$dump"
say "database: $(basename "$dump") ($(wc -c <"$dump" | tr -d ' ') bytes, pg_restore --list ok)"

OPENBAO_BACKUP_DIR="$dir" ./scripts/backup-openbao.sh scheduled >>"$log" 2>&1 ||
  failed "the OpenBao snapshot failed (see $log)"

# Retention: the newest $keep of each kind of scheduled file.
prune() {
  # shellcheck disable=SC2012 # names are ours: no spaces, no newlines
  ls -1t "$dir"/$1 2>/dev/null | tail -n +"$((keep + 1))" | while read -r old; do
    rm -f "$old"
    say "removed $(basename "$old") (older than the newest $keep)"
  done
}

prune 'alex_claw_prod-*-scheduled.dump'
prune 'openbao-*-scheduled.snap'

say "done"
