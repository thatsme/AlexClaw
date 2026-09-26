#!/bin/sh
# Backs up OpenBao: a raft snapshot, next to the database backups and named
# like them — $BACKUP_DIR (default ~/backups)/openbao-<timestamp>-<reason>.snap
# — readable by its owner only, and checked before this says it is done.
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

BACKUP_DIR="${BACKUP_DIR:-$HOME/backups}"
stamp=$(date +%Y%m%d-%H%M%S)
BACKUP_NAME="openbao-${stamp}-${reason}.snap"
target="$BACKUP_DIR/$BACKUP_NAME"

mkdir -p "$BACKUP_DIR"
export BACKUP_DIR BACKUP_NAME

docker compose --profile backup run --rm --no-deps openbao-backup

# Checked here too: the file is where it should be, not empty, and owner-only.
[ -s "$target" ] || { echo "backup-openbao: $target is missing or empty" >&2; exit 1; }
chmod 600 "$target"
mode=$(stat -f '%Lp' "$target" 2>/dev/null || stat -c '%a' "$target")
[ "$mode" = "600" ] || { echo "backup-openbao: $target has mode $mode, not 600" >&2; exit 1; }

size=$(wc -c < "$target" | tr -d ' ')
echo "backup-openbao: $target ($size bytes, mode 600, snapshot checksums verified)"
