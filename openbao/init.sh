#!/bin/sh
# Initialises OpenBao for AlexClaw, and makes its TLS certificates. Runs as the
# one-shot `openbao-init` service (`openbao-test-init` in the test stack) on
# every start of the stack; see docs/architecture/openbao.md.
#
# 1. Certificates. If OpenBao is not running yet, a new CA and server
#    certificate are made into OpenBao's TLS volume, and the CA certificate
#    into AlexClaw's bootstrap mount. The CA key exists only in this
#    container's /tmp and is gone when it exits. A running OpenBao keeps the
#    certificate it was started with.
# 2. Ready. /tmp/ready tells compose OpenBao may start (it waits for this
#    service to be healthy).
# 3. Initialisation, once. An initialised OpenBao is left as it is. Otherwise:
#    initialise (static seal: recovery keys, no unseal keys), enable kv-v2 at
#    secret/ (one version per secret) and transit with key "alexclaw", write
#    the policy, create the
#    AppRole bound to AlexClaw's address, write role_id and secret_id to the
#    bootstrap mount, print the recovery key once, and revoke the root token.
#    Outside the test stack this needs an operator at a terminal, who confirms
#    the keys are saved offline.
set -eu

: "${OPENBAO_ADDR:?OPENBAO_ADDR is not set}"
: "${OPENBAO_HOSTNAME:?OPENBAO_HOSTNAME is not set}"
: "${ALEXCLAW_ADDRESS:?ALEXCLAW_ADDRESS is not set}"

TLS=/openbao/tls
BOOTSTRAP=/bootstrap
# OpenBao's user, and the group it shares with AlexClaw's user.
BAO_UID=100
SHARED_GID=1000

export BAO_ADDR="$OPENBAO_ADDR"
export BAO_CACERT="$TLS/ca.pem"

say() { printf 'openbao-init: %s\n' "$*"; }
fail() { printf 'openbao-init: %s\n' "$*" >&2; exit 1; }

running() { nc -z -w 2 "$OPENBAO_HOSTNAME" 8200 2>/dev/null; }

make_certificates() {
  work=$(mktemp -d)

  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
    -subj "/CN=AlexClaw OpenBao CA" -keyout "$work/ca.key" -out "$work/ca.pem" 2>/dev/null

  openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -subj "/CN=$OPENBAO_HOSTNAME" -keyout "$work/server.key" -out "$work/server.csr" 2>/dev/null

  printf 'subjectAltName=DNS:%s,IP:127.0.0.1\nextendedKeyUsage=serverAuth\n' "$OPENBAO_HOSTNAME" \
    > "$work/ext"

  openssl x509 -req -in "$work/server.csr" -CA "$work/ca.pem" -CAkey "$work/ca.key" \
    -CAcreateserial -days 825 -extfile "$work/ext" -out "$work/server.pem" 2>/dev/null

  install -o "$BAO_UID" -g "$SHARED_GID" -m 0400 "$work/server.key" "$TLS/server.key"
  install -o root -g "$SHARED_GID" -m 0444 "$work/server.pem" "$TLS/server.pem"
  install -o root -g "$SHARED_GID" -m 0444 "$work/ca.pem" "$TLS/ca.pem"
  install -o root -g "$SHARED_GID" -m 0444 "$work/ca.pem" "$BOOTSTRAP/ca.pem"

  # /tmp is this container's tmpfs: the CA key goes with it.
  rm -rf "$work"
  say "new TLS certificate for $OPENBAO_HOSTNAME; the CA key is discarded"
}

# bao status: 0 unsealed, 2 sealed, 1 error (not answering).
wait_for_openbao() {
  tries=0
  until bao status >/dev/null 2>&1 || [ $? -eq 2 ]; do
    tries=$((tries + 1))
    [ "$tries" -le 120 ] || fail "OpenBao did not answer at $OPENBAO_ADDR within 60 seconds"
    sleep 0.5
  done
}

wait_until_unsealed() {
  tries=0
  until bao status >/dev/null 2>&1; do
    tries=$((tries + 1))
    [ "$tries" -le 60 ] || fail "OpenBao did not unseal within 30 seconds: is the unseal key mounted?"
    sleep 0.5
  done
}

initialised() { bao status -format=json 2>/dev/null | grep -q '"initialized": true'; }

confirm_saved() {
  while :; do
    printf 'Saved the unseal key file AND the recovery key above offline? Type SAVED: '
    read -r answer || fail "no confirmation: the root token is revoked; store the unseal key file and the recovery key before closing this terminal"
    [ "$answer" = "SAVED" ] && return 0
  done
}

configure() {
  # The file audit device is declared in config.hcl; OpenBao must actually
  # have it on before AlexClaw is given any access (S8).
  bao audit list -format=json 2>/dev/null | grep -q '"alexclaw/"' ||
    fail "the file audit device is not enabled: AlexClaw is not given access"

  bao secrets enable -path=secret kv-v2 >/dev/null
  # One version per secret: a rotation leaves no readable old value. The mount
  # holds AlexClaw's secrets and nothing else, so the setting is the mount's.
  bao write secret/config max_versions=1 >/dev/null
  bao secrets enable transit >/dev/null
  bao write -f transit/keys/alexclaw >/dev/null
  # The admin's second factor: OpenBao holds the key and checks the codes.
  bao secrets enable totp >/dev/null

  bao policy write alexclaw - >/dev/null <<'POLICY'
path "secret/data/alexclaw/*" {
  capabilities = ["create", "read", "update"]
}

# The token renews itself before it expires; with no default policy on it,
# this is the one self-service path it needs.
path "auth/token/renew-self" {
  capabilities = ["update"]
}

# Deleting a secret destroys every version and its metadata.
path "secret/metadata/alexclaw/*" {
  capabilities = ["delete"]
}

# The MCP key is kept as an HMAC under this key: recognised, never stored.
path "transit/hmac/alexclaw" {
  capabilities = ["update"]
}

# Recovery codes are checked against their HMACs here, in constant time.
path "transit/verify/alexclaw" {
  capabilities = ["update"]
}

# The admin's TOTP key: enrolled (update writes it), described (read gives
# metadata, never the secret) and deleted when 2FA is turned off.
path "totp/keys/admin" {
  capabilities = ["read", "update", "delete"]
}

# Codes are checked here. A read of this path would generate a code, so it
# is not granted.
path "totp/code/admin" {
  capabilities = ["update"]
}
POLICY

  bao auth enable approle >/dev/null
  # Only what the alexclaw policy grants: no default policy on its tokens.
  bao write auth/approle/role/alexclaw \
    token_policies=alexclaw \
    token_no_default_policy=true \
    secret_id_bound_cidrs="$ALEXCLAW_ADDRESS/32" \
    token_bound_cidrs="$ALEXCLAW_ADDRESS/32" \
    token_ttl=1h token_max_ttl=24h \
    secret_id_ttl=0 secret_id_num_uses=0 >/dev/null

  role_id=$(bao read -field=role_id auth/approle/role/alexclaw/role-id)
  secret_id=$(bao write -f -field=secret_id auth/approle/role/alexclaw/secret-id)

  # Written in /tmp, then installed: a file left read-only by an earlier run is
  # replaced, not written into.
  work=$(mktemp -d)
  printf '%s' "$role_id" > "$work/role_id"
  printf '%s' "$secret_id" > "$work/secret_id"
  install -o root -g "$SHARED_GID" -m 0440 "$work/role_id" "$BOOTSTRAP/role_id"
  install -o root -g "$SHARED_GID" -m 0440 "$work/secret_id" "$BOOTSTRAP/secret_id"
  rm -rf "$work"
  unset role_id secret_id
  say "AppRole bound to $ALEXCLAW_ADDRESS; role_id and secret_id written to the bootstrap mount"
}

revoke_root() {
  if [ -n "${BAO_TOKEN:-}" ]; then
    bao token revoke -self >/dev/null 2>&1 && say "root token revoked" ||
      say "COULD NOT REVOKE THE ROOT TOKEN: revoke it by hand"
    unset BAO_TOKEN
  fi
}

initialise() {
  if [ "${OPENBAO_INIT_UNATTENDED:-}" != "1" ] && [ ! -t 0 ]; then
    fail "OpenBao is not initialised. Initialise it once, at a terminal: docker compose run --rm openbao-init"
  fi

  out=$(bao operator init -recovery-shares=1 -recovery-threshold=1)
  BAO_TOKEN=$(printf '%s\n' "$out" | sed -n 's/^Initial Root Token: //p')
  recovery=$(printf '%s\n' "$out" | sed -n 's/^Recovery Key 1: //p')
  unset out
  [ -n "$BAO_TOKEN" ] || fail "operator init returned no root token"
  export BAO_TOKEN
  trap revoke_root EXIT

  printf '\n  Recovery key (shown once, never again): %s\n' "$recovery"
  printf '  Unseal key: the file "key" in the host directory OPENBAO_UNSEAL_DIR\n'
  printf '  (default ./openbao/unseal). Losing it loses every secret in OpenBao.\n\n'
  unset recovery

  if [ "${OPENBAO_INIT_UNATTENDED:-}" != "1" ]; then
    confirm_saved
  fi

  wait_until_unsealed
  configure
  revoke_root
  trap - EXIT
  say "OpenBao initialised"
}

if running; then
  say "OpenBao is running: its certificate is kept"
else
  make_certificates
fi

touch /tmp/ready
wait_for_openbao

if initialised; then
  say "OpenBao is already initialised: nothing to do"
  exit 0
fi

initialise
