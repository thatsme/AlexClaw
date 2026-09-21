#!/bin/sh
# Creates the application's database role when a fresh volume is initialised.
# PostgreSQL runs this once, as the owner (POSTGRES_USER), and never again —
# an existing volume gets the role from the upgrade guide instead.
#
# The role can connect and nothing else. Its table privileges come from the
# grant step the migrate service runs after every migration.
#
# Values reach SQL as psql variables (:"name" quotes an identifier, :'value' a
# literal), never pasted into the statement text.
set -eu

: "${DATABASE_APP_USERNAME:?the application role's name}"
: "${DATABASE_APP_PASSWORD:?the application role's password}"

psql -v ON_ERROR_STOP=1 \
  -v app_user="$DATABASE_APP_USERNAME" \
  -v app_password="$DATABASE_APP_PASSWORD" \
  -v db="$POSTGRES_DB" \
  --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<'SQL'
CREATE ROLE :"app_user" LOGIN PASSWORD :'app_password'
  NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
GRANT CONNECT ON DATABASE :"db" TO :"app_user";
GRANT USAGE ON SCHEMA public TO :"app_user";
SQL
