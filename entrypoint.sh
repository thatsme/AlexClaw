#!/bin/sh
set -e

# BEAM distribution: set node name and cookie if provided
[ -n "$NODE_NAME" ] && export RELEASE_NODE="$NODE_NAME"
[ -n "$CLUSTER_COOKIE" ] && export RELEASE_COOKIE="$CLUSTER_COOKIE"

# Long-name distribution: names containing a dot need -name mode + EPMD
if echo "$NODE_NAME" | grep -q '\.'; then
  export RELEASE_DISTRIBUTION=name
  echo "Starting EPMD for long-name distribution..."
  epmd -daemon
fi

echo "Running migrations..."
bin/alex_claw eval "AlexClaw.Release.migrate()"

echo "Checking for first-boot seeding..."
bin/alex_claw eval "AlexClaw.Release.seed_examples()"

echo "Starting AlexClaw..."
bin/alex_claw start
