defmodule AlexClaw.Database.RolesTest do
  @moduledoc """
  The application's database role, as the suite runs it: what it may do, what
  the database refuses it, and the check that tells the two roles apart.

  Each refused statement runs in a transaction of its own, because a refused
  statement aborts the transaction it is in.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.{AuditEntry, AuditLog}
  alias AlexClaw.Database.Roles

  # A statement the database would allow may still have to wait for a lock —
  # TRUNCATE does — so a lock timeout turns "allowed, but blocked" into a fast
  # failure instead of a hung suite.
  defp refused?(sql) do
    {:error, reason} =
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL lock_timeout = '2s'")
        sql |> Repo.query() |> result()
      end)

    reason
  end

  defp result({:ok, _}), do: :allowed
  defp result({:error, %Postgrex.Error{postgres: %{code: code}}}), do: Repo.rollback(code)

  defp owner_connection do
    {:ok, conn} =
      Postgrex.start_link(
        hostname: System.fetch_env!("DATABASE_HOSTNAME"),
        username: System.fetch_env!("DATABASE_OWNER_USERNAME"),
        password: System.fetch_env!("DATABASE_OWNER_PASSWORD"),
        database: Repo.config()[:database]
      )

    on_exit(fn -> Process.exit(conn, :normal) end)
    conn
  end

  defp app_connection do
    {:ok, conn} =
      Postgrex.start_link(
        Keyword.take(Repo.config(), [:hostname, :username, :password, :database])
      )

    on_exit(fn -> Process.exit(conn, :normal) end)
    conn
  end

  test "the suite connects as the application role, not the owner" do
    assert %{rows: [["alexclaw_app"]]} = Repo.query!("SELECT current_user")
  end

  describe "the audit log is append-only for the application" do
    test "it may insert and read" do
      assert AuditLog.record_admin_write("fp-roles", "roles: insert allowed") == :ok
      assert Repo.exists?(from(e in AuditEntry, where: e.reason == "roles: insert allowed"))
    end

    test "update, delete and truncate are refused by the database" do
      assert refused?("UPDATE auth_audit_log SET reason = 'x' WHERE false") ==
               :insufficient_privilege

      assert refused?("DELETE FROM auth_audit_log WHERE false") == :insufficient_privilege
      assert refused?("TRUNCATE auth_audit_log") == :insufficient_privilege
    end

    test "it cannot drop or alter the table" do
      assert refused?("ALTER TABLE auth_audit_log DISABLE TRIGGER ALL") == :insufficient_privilege
      assert refused?("DROP TABLE auth_audit_log") == :insufficient_privilege
    end
  end

  test "the migration history is read-only for the application" do
    assert refused?("DELETE FROM schema_migrations WHERE false") == :insufficient_privilege

    assert refused?("INSERT INTO schema_migrations (version) VALUES (1)") ==
             :insufficient_privilege
  end

  test "the application cannot run anything outside the database" do
    assert refused?("COPY (SELECT 1) TO PROGRAM 'true'") == :insufficient_privilege
  end

  describe "pruning" do
    # Inserted by the application inside the sandbox — it may set any
    # timestamp — so the rows roll back with the test.
    test "deletes rows older than thirty days, and nothing younger" do
      for {reason, days} <- [{"roles: old", 31}, {"roles: young", 29}] do
        Repo.query!(
          "INSERT INTO auth_audit_log (caller, caller_type, permission, decision, reason, principal, inserted_at) " <>
            "VALUES ('t', 't', 't', 'deny', $1, 'owner', now() - make_interval(days => $2))",
          [reason, days]
        )
      end

      {pruned, nil} = AuditLog.prune()

      assert pruned >= 1
      refute Repo.exists?(from(e in AuditEntry, where: e.reason == "roles: old"))
      assert Repo.exists?(from(e in AuditEntry, where: e.reason == "roles: young"))
    end
  end

  describe "check/1" do
    test "passes for the application role" do
      assert Roles.check(app_connection()) == :ok
    end

    test "names every way the owner is not the application role" do
      assert {:error, problems} = Roles.check(owner_connection())

      text = Enum.join(problems, "\n")
      assert text =~ "is a superuser"
      assert text =~ "can create roles"
      assert text =~ "can create databases"
      assert text =~ "bypasses row-level security"
      assert text =~ "owns tables: " and text =~ "auth_audit_log"
    end
  end

  test "grant/2 refuses a role name that is not a plain identifier" do
    assert_raise ArgumentError, ~r/not a plain role name/, fn ->
      Roles.grant(owner_connection(), "alexclaw_app; DROP TABLE settings")
    end
  end
end
