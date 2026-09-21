defmodule AlexClaw.Repo.Migrations.CreatePruneAuthAuditLog do
  use Ecto.Migration

  # The application role may insert into auth_audit_log and read it, never
  # delete from it. Retention still has to happen, so it happens here: a
  # function owned by the owner, run with the owner's rights, that deletes only
  # rows older than thirty days. The floor is in the function, not a parameter,
  # so the application cannot ask for less.
  def up do
    execute("""
    CREATE OR REPLACE FUNCTION prune_auth_audit_log() RETURNS bigint
    LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
      WITH pruned AS (
        DELETE FROM auth_audit_log WHERE inserted_at < now() - interval '30 days' RETURNING 1
      )
      SELECT count(*) FROM pruned
    $$
    """)

    execute("REVOKE ALL ON FUNCTION prune_auth_audit_log() FROM PUBLIC")
  end

  def down do
    execute("DROP FUNCTION IF EXISTS prune_auth_audit_log()")
  end
end
