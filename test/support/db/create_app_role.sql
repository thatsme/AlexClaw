-- The test database's application role, created the way the upgrade guide
-- has an operator create production's: once, by the owner, with nothing but
-- the right to connect. Its table privileges come from the same grant step a
-- release's migrate runs.
CREATE ROLE alexclaw_app LOGIN PASSWORD 'apptest'
  NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
GRANT CONNECT ON DATABASE alex_claw_test TO alexclaw_app;
GRANT USAGE ON SCHEMA public TO alexclaw_app;
