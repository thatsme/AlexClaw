#!/bin/sh
# Backs up OpenBao: a raft snapshot, next to the database backups and named
# like them — $OPENBAO_BACKUP_DIR (default ~/backups)/
# openbao-<timestamp>-<reason>.snap — readable by its owner only, and checked
# before this says it is done. Never into BACKUP_DIR, which AlexClaw mounts.
#
#   scripts/backup-openbao.sh [reason]        (make backup-openbao REASON=…)
#
# The snapshot is taken by the one-shot `openbao-backup` service with the
# backup AppRole, which may read a snapshot and nothing else; AlexClaw never
# holds that credential. It holds OpenBao's data, sealed. It does NOT hold the
# unseal key (OPENBAO_UNSEAL_DIR/key): keep that, and the recovery key, with
# it — offline — or the snapshot cannot be opened. Restoring: see
# docs/architecture/openbao.md, "Backing up and restoring OpenBao".
set -eu

cd "$(dirname "$0")/.." || exit 1

reason="${1:-manual}"
case "$reason" in
  *[!A-Za-z0-9_-]*) echo "backup-openbao: the reason may hold letters, digits, - and _ only" >&2; exit 2 ;;
esac

OPENBAO_BACKUP_DIR="${OPENBAO_BACKUP_DIR:-$HOME/backups}"
stamp=$(date +%Y%m%d-%H%M%S)
BACKUP_NAME="openbao-${stamp}-${reason}.snap"
target="$OPENBAO_BACKUP_DIR/$BACKUP_NAME"

# BACKUP_DIR (the environment's, else .env's, else compose's default
# ./backups) is the db_backup skill's directory, which AlexClaw mounts: a
# snapshot written there, or anywhere below it, would be readable by AlexClaw.
# Refused, before anything is created.
skill_dir="${BACKUP_DIR:-$(sed -n 's/^BACKUP_DIR=//p' .env 2>/dev/null | tail -1)}"
skill_dir="${skill_dir:-./backups}"

# The absolute path of $1, resolving the part of it that exists.
absolute() {
  dir=$1 rest=""
  while [ ! -d "$dir" ]; do
    rest="/$(basename "$dir")$rest"
    dir=$(dirname "$dir")
  done
  printf '%s%s\n' "$(cd "$dir" && pwd -P)" "$rest"
}

mounted=$(absolute "$skill_dir")
snapshots=$(absolute "$OPENBAO_BACKUP_DIR")
case "$snapshots/" in
  "$mounted"/*)
    echo "backup-openbao: refused: OPENBAO_BACKUP_DIR ($snapshots) is BACKUP_DIR or inside it, which AlexClaw mounts; choose another directory" >&2
    exit 2
    ;;
esac

mkdir -p "$OPENBAO_BACKUP_DIR"
export OPENBAO_BACKUP_DIR

docker compose --profile backup run --rm --no-deps -e BACKUP_NAME="$BACKUP_NAME" openbao-backup

# Checked here too: the file is where it should be, not empty, and owner-only.
[ -s "$target" ] || { echo "backup-openbao: $target is missing or empty" >&2; exit 1; }
chmod 600 "$target"
mode=$(stat -f '%Lp' "$target" 2>/dev/null || stat -c '%a' "$target")
[ "$mode" = "600" ] || { echo "backup-openbao: $target has mode $mode, not 600" >&2; exit 1; }

size=$(wc -c < "$target" | tr -d ' ')
echo "backup-openbao: $target ($size bytes, mode 600, snapshot checksums verified)"
