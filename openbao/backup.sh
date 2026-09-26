#!/bin/sh
# Takes a raft snapshot of OpenBao into /backups/$BACKUP_NAME. Runs as the
# one-shot `openbao-backup` service (compose profile "backup"), started by
# scripts/backup-openbao.sh; see docs/architecture/openbao.md.
#
# It logs in with the backup AppRole (policy "backup": reading a snapshot and
# nothing else; credentials in /credentials, which AlexClaw never mounts),
# with a single-use token, saves the snapshot readable by its owner only, and
# checks it (the archive's own checksums). The snapshot holds OpenBao's data, sealed; it does not hold the
# unseal key.
set -eu

: "${OPENBAO_ADDR:?OPENBAO_ADDR is not set}"
: "${BACKUP_NAME:?BACKUP_NAME is not set}"

CREDENTIALS=/credentials
OUT="/backups/$BACKUP_NAME"

export BAO_ADDR="$OPENBAO_ADDR"
export BAO_CACERT="$CREDENTIALS/ca.pem"

say() { printf 'openbao-backup: %s\n' "$*"; }
fail() { printf 'openbao-backup: %s\n' "$*" >&2; exit 1; }

[ -r "$CREDENTIALS/role_id" ] && [ -r "$CREDENTIALS/secret_id" ] ||
  fail "no backup credentials in $CREDENTIALS: was OpenBao initialised by this release's openbao-init?"
[ -e "$OUT" ] && fail "$OUT exists: not overwritten"

BAO_TOKEN=$(bao write -field=token auth/approle/login \
  role_id="$(cat "$CREDENTIALS/role_id")" \
  secret_id="$(cat "$CREDENTIALS/secret_id")") || fail "login with the backup AppRole failed"
# Single use: the snapshot read below uses it up (token_num_uses=1).
export BAO_TOKEN

umask 077
bao operator raft snapshot save "$OUT" || fail "snapshot not saved"
chmod 600 "$OUT"

size=$(wc -c < "$OUT")
[ "$size" -gt 0 ] || fail "snapshot is empty"

# OpenBao has no `snapshot inspect`. A raft snapshot is a gzipped tar holding
# meta.json, state.bin and their SHA256SUMS: all three must be there, and the
# sums must hold.
check=$(mktemp -d)
tar -xzf "$OUT" -C "$check" 2>/dev/null || fail "snapshot is not a gzipped tar"
for part in meta.json state.bin SHA256SUMS; do
  [ -s "$check/$part" ] || fail "snapshot lacks $part"
done
(cd "$check" && sha256sum -c SHA256SUMS >/dev/null 2>&1) || fail "snapshot checksums do not match"
rm -rf "$check"

say "snapshot saved: $BACKUP_NAME ($size bytes); its checksums verified"
