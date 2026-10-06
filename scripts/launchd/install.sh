#!/bin/sh
# Installs (or reinstalls) the nightly backup LaunchAgent for this checkout:
# ~/Library/LaunchAgents/com.alexclaw.backup.plist, loaded at once.
#
#   scripts/launchd/install.sh            install and load
#   scripts/launchd/install.sh remove     unload and remove
set -eu

cd "$(dirname "$0")/../.." || exit 1
repo=$(pwd)
agent="$HOME/Library/LaunchAgents/com.alexclaw.backup.plist"
domain="gui/$(id -u)"

launchctl bootout "$domain/com.alexclaw.backup" 2>/dev/null || true

if [ "${1:-}" = "remove" ]; then
  rm -f "$agent"
  echo "com.alexclaw.backup removed"
  exit 0
fi

mkdir -p "$(dirname "$agent")"
sed "s#__REPO__#$repo#g" scripts/launchd/com.alexclaw.backup.plist >"$agent"
plutil -lint "$agent" >/dev/null
launchctl bootstrap "$domain" "$agent"
echo "com.alexclaw.backup installed: nightly at 03:30, running $repo/scripts/backup-scheduled.sh"
