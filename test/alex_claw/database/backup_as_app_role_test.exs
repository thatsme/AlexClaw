defmodule AlexClaw.Database.BackupAsAppRoleTest do
  @moduledoc """
  A full backup is still whole when made as the application role: the backup
  download and the backup skill run pg_dump with DATABASE_USERNAME, which is
  that role, and it may read every table — the audit log included.

  pg_dump connects outside the sandbox, so it sees the schema and whatever is
  committed; what is checked is that it runs, and what it covers.
  """
  use ExUnit.Case, async: true
  @moduletag :integration

  test "pg_dump as the application role dumps every table, the audit log included" do
    {output, status} =
      System.cmd(
        "pg_dump",
        [
          "-h",
          System.fetch_env!("DATABASE_HOSTNAME"),
          "-U",
          System.fetch_env!("DATABASE_USERNAME"),
          "-d",
          AlexClaw.Repo.config()[:database],
          # The flags the backup download and the backup skill use.
          "--no-owner",
          "--no-privileges",
          "--clean",
          "--if-exists"
        ],
        env: [{"PGPASSWORD", System.fetch_env!("DATABASE_PASSWORD")}],
        stderr_to_stdout: true
      )

    assert status == 0, output

    for table <- Map.keys(AlexClaw.Database.Roles.privileges()) do
      assert output =~ "CREATE TABLE public.#{table} ", "#{table} is missing from the dump"
    end

    assert output =~ "COPY public.auth_audit_log"
    assert output =~ "FUNCTION public.prune_auth_audit_log()"
  end
end
