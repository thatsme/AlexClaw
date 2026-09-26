#!/bin/sh
# Turns the admin's second factor off, for when the authenticator AND every
# recovery code are lost (make reset-2fa). Runs AlexClaw.Release.reset_second_factor/0
# inside the running node: 2FA off, the TOTP key deleted in OpenBao, every
# recovery code removed, an audit row written, and a warning printed.
#
# Only someone with a shell on this host can run it — someone who can already
# read the database and OpenBao's volumes. Nothing else reaches it: no page,
# chat, MCP client or skill. After it, set 2FA up again on the Services page.
#
# It asks for RESET to be typed; RESET_2FA_CONFIRM=RESET answers for a script.
set -eu

cd "$(dirname "$0")/.." || exit 1

cat <<'EOF'
This turns the second factor OFF: the authenticator key is deleted and every
recovery code is removed. Until 2FA is set up again, the admin UI is
read-only and nothing that needs a code can run.
EOF

answer="${RESET_2FA_CONFIRM:-}"
if [ -z "$answer" ]; then
  printf 'Type RESET to go on: '
  read -r answer || answer=""
fi
[ "$answer" = "RESET" ] || { echo "reset-2fa: not confirmed; nothing changed" >&2; exit 2; }

docker compose exec -T alexclaw-prod bin/alex_claw rpc 'AlexClaw.Release.reset_second_factor()'
