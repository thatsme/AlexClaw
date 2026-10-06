-- The read-only role AlexClaw connects as: it may read the demo's tables and
-- nothing else, and every session it opens is read-only. Run by
-- initdb/03-reader.sh with -v reader_password=… (the value of
-- DEMO_READER_PASSWORD); safe to run again.

SELECT format('CREATE ROLE alexclaw_reader LOGIN PASSWORD %L', :'reader_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'alexclaw_reader')
\gexec

SELECT format('ALTER ROLE alexclaw_reader WITH LOGIN PASSWORD %L', :'reader_password')
\gexec

ALTER ROLE alexclaw_reader SET default_transaction_read_only = on;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM alexclaw_reader;
GRANT CONNECT ON DATABASE :"DBNAME" TO alexclaw_reader;
GRANT USAGE ON SCHEMA public TO alexclaw_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO alexclaw_reader;
