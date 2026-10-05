#!/bin/sh
# A restore drill: proves an OpenBao snapshot can be restored and read, and
# that the unseal key and the recovery key kept offline are the right ones —
# without touching the running OpenBao.
#
#   scripts/drill-restore-openbao.sh [snapshot]          the full drill
#   scripts/drill-restore-openbao.sh --restore-only [snapshot]
#
# The snapshot defaults to the newest ~/backups/openbao-*.snap. The drill:
#   1. starts a throwaway OpenBao: the production image, the same unseal key
#      file (mounted read-only), no network at all, its storage in a tmpfs;
#   2. initialises it and restores the snapshot into it, which makes it the
#      snapshot's OpenBao — it unseals only with the key it was taken under;
#   3. asks for the RECOVERY KEY (not echoed, passed on stdin, never on a
#      command line) and makes a root token for the restored data with it;
#   4. reads back, as names and lengths only, every secret the production
#      catalogue names, and the transit and TOTP keys;
#   5. revokes the token and removes the throwaway: nothing of it remains.
# --restore-only stops after step 2 (no recovery key needed): it proves the
# snapshot opens with the unseal key file.
set -eu

cd "$(dirname "$0")/.." || exit 1

mode=full
if [ "${1:-}" = "--restore-only" ]; then mode=restore; shift; fi

snapshot="${1:-$(ls -1t "${OPENBAO_BACKUP_DIR:-$HOME/backups}"/openbao-*.snap 2>/dev/null | head -1)}"
[ -f "$snapshot" ] || { echo "drill: no snapshot found" >&2; exit 2; }

unseal_dir="${OPENBAO_UNSEAL_DIR:-$(sed -n 's/^OPENBAO_UNSEAL_DIR=//p' .env 2>/dev/null | tail -1)}"
unseal_dir="${unseal_dir:-./openbao/unseal}"
[ -f "$unseal_dir/key" ] || { echo "drill: no unseal key file in $unseal_dir" >&2; exit 2; }
unseal_dir=$(cd "$unseal_dir" && pwd)

image=$(sed -n 's/^ *image: \(openbao\/openbao:.*\)$/\1/p' docker-compose.yml | head -1)
name="alexclaw-drill-openbao"
work=$(mktemp -d)

cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

step() { printf '\n== %s\n' "$*"; }

# The production configuration, but with no TLS (there is no network to
# reach it) and with the recovery-key root endpoints open (nothing can reach
# them). No audit device: the throwaway keeps nothing.
cat >"$work/config.hcl" <<'HCL'
storage "raft" {
  path    = "/openbao/file"
  node_id = "drill"
}
listener "tcp" {
  address     = "127.0.0.1:8200"
  tls_disable = true
  disable_unauthed_generate_root_endpoints = false
}
seal "static" {
  current_key_id = "1"
  current_key    = "file:///openbao/unseal/key"
}
HCL

# Step 2, inside the throwaway.
cat >"$work/restore.sh" <<'SH'
set -eu
i=0; until bao status 2>&1 | grep -q '^Initialized'; do
  i=$((i + 1)); [ $i -lt 30 ] || { echo "FAIL: the throwaway OpenBao did not start"; exit 1; }; sleep 1
done
field() { sed -n "s/.*\"$1\": *\"\([^\"]*\)\".*/\1/p" | head -1; }
# The throwaway's own root token, only to restore with; it ends with it.
export BAO_TOKEN=$(bao operator init -format=json | tr -d '\n' | field root_token)
bao operator raft snapshot restore -force /restore/drill.snap
i=0; until bao status 2>/dev/null | grep -qE '^Sealed +false'; do
  i=$((i + 1))
  [ $i -lt 15 ] || { echo "FAIL: the restored snapshot stays sealed: this unseal key file is not the one it was taken with"; exit 1; }
  sleep 1
done
bao status | grep -E '^(Initialized|Sealed)'
SH

# Steps 3–4, inside the throwaway: the recovery key on the first line of
# stdin, then the catalogue's secret names, one per line.
cat >"$work/read.sh" <<'SH'
set -u
IFS= read -r key
field() { sed -n "s/.*\"$1\": *\"\([^\"]*\)\".*/\1/p" | head -1; }
decode() {
  enc=$1; while [ $(( ${#enc} % 4 )) -ne 0 ]; do enc="$enc="; done
  set -- $(printf %s "$2" | od -An -tu1)
  for b in $(printf %s "$enc" | base64 -d | od -An -tu1); do
    printf "\\$(printf %03o $(( b ^ $1 )))"; shift
  done
}
otp=$(head -c 200 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 26)
nonce=$(bao write -format=json sys/generate-root/attempt otp="$otp" | field nonce)
enc=$(bao write -format=json sys/generate-root/update key="$key" nonce="$nonce" 2>/dev/null | field encoded_token)
unset key
[ -n "$enc" ] || { echo "FAIL: the recovery key was refused"; exit 1; }
export BAO_TOKEN=$(decode "$enc" "$otp")
fail=0
while IFS= read -r name; do
  [ -n "$name" ] || continue
  if v=$(bao kv get -mount=secret -field=value "alexclaw/secrets/$name" 2>/dev/null); then
    echo "secret $name: ok, $(printf %s "$v" | wc -c | tr -d ' ') bytes"
  else
    echo "secret $name: MISSING"; fail=1
  fi
done
if bao read transit/keys/alexclaw >/dev/null 2>&1; then echo "transit key alexclaw: ok"; else echo "transit key alexclaw: MISSING"; fail=1; fi
if bao read totp/keys/admin >/dev/null 2>&1; then echo "TOTP key admin: ok"; else echo "TOTP key admin: absent (no second factor in this snapshot)"; fi
bao token revoke -self >/dev/null
if [ $fail = 0 ]; then echo PASS; else echo FAIL; fi
SH
chmod 644 "$work"/*
chmod 755 "$work"

step "Throwaway OpenBao (no network, storage in memory), snapshot $(basename "$snapshot")"
docker rm -f "$name" >/dev/null 2>&1 || true
docker run -d --name "$name" --network none --user 100:1000 --read-only \
  --cap-drop ALL --security-opt no-new-privileges:true \
  --tmpfs /tmp --tmpfs /openbao/file:uid=100,gid=1000,mode=0700 \
  -e SKIP_CHOWN=1 -e BAO_ADDR=http://127.0.0.1:8200 \
  -e BAO_API_ADDR=http://127.0.0.1:8200 -e BAO_CLUSTER_ADDR=http://127.0.0.1:8201 \
  -v "$work/config.hcl:/openbao/config/config.hcl:ro" \
  -v "$work:/drill:ro" \
  -v "$unseal_dir:/openbao/unseal:ro" \
  -v "$snapshot:/restore/drill.snap:ro" \
  "$image" server -config=/openbao/config/config.hcl >/dev/null

docker exec "$name" sh /drill/restore.sh
echo "restored: the snapshot unsealed with the unseal key file"

if [ "$mode" = restore ]; then
  echo "PASS (restore only)"
  exit 0
fi

step "The recovery key (it is not shown; Ctrl-C to stop)"
printf 'Recovery key: '
stty -echo 2>/dev/null || true
IFS= read -r recovery
stty echo 2>/dev/null || true
printf '\n'

owner=$(sed -n 's/^DATABASE_OWNER_USERNAME=//p' .env | tail -1 | tr -d "\"' \r")
catalogue=$(docker exec alexclaw-db-prod psql -U "$owner" -d alex_claw_prod -tAc \
  "SELECT name FROM secrets ORDER BY name")

step "Reading the restored data back (names and lengths only)"
result=$( { printf '%s\n' "$recovery"; printf '%s\n' "$catalogue"; } |
  docker exec -i "$name" sh /drill/read.sh || true)
unset recovery
printf '%s\n' "$result"
case "$result" in *PASS) exit 0 ;; *) exit 1 ;; esac
