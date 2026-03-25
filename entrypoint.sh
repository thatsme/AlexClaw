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

# Wait for PostgreSQL to be ready (handles restart timing)
DB_HOST="${DATABASE_HOSTNAME:-db}"
DB_USER="${DATABASE_USERNAME:-alexclaw}"
echo "Waiting for database at ${DB_HOST}..."
for i in $(seq 1 30); do
  if pg_isready -h "$DB_HOST" -U "$DB_USER" -q 2>/dev/null; then
    echo "Database is ready."
    break
  fi
  if [ "$i" = "30" ]; then
    echo "Database not ready after 30 attempts, proceeding anyway..."
  fi
  sleep 1
done

echo "Running migrations..."
bin/alex_claw eval "AlexClaw.Release.migrate()"

echo "Checking for first-boot seeding..."
bin/alex_claw eval "AlexClaw.Release.seed_examples()"

echo "Starting AlexClaw..."
bin/alex_claw start
