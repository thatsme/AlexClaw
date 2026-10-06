#!/bin/sh
# The read-only role, with the password from DEMO_READER_PASSWORD
# (docker-compose.yml). No password, no demo: the container stops here rather
# than start a role nobody can log in as, or one with a guessable password.
set -eu

if [ -z "${DEMO_READER_PASSWORD:-}" ]; then
  echo "demo-db: set DEMO_READER_PASSWORD in .env (see docs/demo/sql-demo.md)" >&2
  exit 1
fi

psql -v ON_ERROR_STOP=1 -X -q -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  -v reader_password="$DEMO_READER_PASSWORD" -f /demo/reader.sql
