defmodule AlexClaw.Auth.AuditGapsTest do
  @moduledoc """
  What happened is in the audit log, even when the rest was undone (S8 M4;
  THREAT_MODEL P8).

  - A secret's value set inside a transaction that rolls back stays set in
    OpenBao, so its row stays too: a secret's catalogue rows are written on
    their own connection, not in the caller's transaction.
  - A secret is handed out only once its use is recorded: a resolve whose row
    cannot be written refuses, with `{:error, :audit_failed}`.
  - A control-plane change that fails leaves a refusal row, after the
    rollback that took its own row with it.
  - The application role cannot move the audit log's sequence (`setval`),
    which would make every later row collide.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :vault

  alias AlexClaw.Auth.{AuditEntry, Elevation}
  alias AlexClaw.{ControlPlane, Secrets}
  alias AlexClaw.ControlPlane.Context

  defp rows(like) do
    AlexClaw.TaskDrain.drain()
    Repo.all(from(e in AuditEntry, where: like(e.reason, ^like)))
  end

  defp secret do
    name = "audit_gap_#{System.unique_integer([:positive])}"
    {:ok, _} = Secrets.define(%{name: name, kind: "api_token", binding: ["host:example.com"]})
    name
  end

  test "a value set in a transaction that rolls back keeps its row" do
    name = secret()

    {:error, :undone} =
      Repo.transaction(fn ->
        :ok = Secrets.put_value(name, "value-set-then-undone")
        Repo.rollback(:undone)
      end)

    assert rows("secret #{name}: value set%") != []
  end

  test "a resolve whose row cannot be written hands out nothing" do
    name = secret()
    :ok = Secrets.put_value(name, "value-behind-a-lost-row")

    # Text PostgreSQL refuses to store: the row cannot be written.
    destination = "host:example.com\u0000"

    assert {:error, :audit_failed} =
             Secrets.resolve(name, for: destination, bindings: [destination])
  end

  test "a change that fails leaves a refusal row" do
    sid = Elevation.new_sid()
    on_exit(fn -> AlexClaw.SandboxCleanup.run(fn -> Elevation.revoke(sid) end) end)
    AlexClaw.Config.set("auth.totp.enabled", "true", type: "boolean", category: "auth")
    {:ok, _} = Elevation.grant(sid)

    params = %{key: "custom.api_key", value: "x", opts: []}
    assert {:error, _reason} = ControlPlane.perform(:set_setting, params, Context.admin_ui(sid))

    assert [row] = rows("%custom.api_key%")
    assert row.decision == "deny"
  end

  test "the application role cannot move the audit log's sequence" do
    %{rows: [[sequence]]} =
      Repo.query!("SELECT pg_get_serial_sequence('public.auth_audit_log', 'id')")

    {:error, code} =
      Repo.transaction(fn ->
        # Set to where it already is: harmless if it were allowed, since
        # setval is not undone by a rollback.
        sql = "SELECT setval($1::text::regclass, (SELECT last_value FROM #{sequence}))"

        case Repo.query(sql, [sequence]) do
          {:ok, _} -> Repo.rollback(:allowed)
          {:error, %Postgrex.Error{postgres: %{code: code}}} -> Repo.rollback(code)
        end
      end)

    assert code == :insufficient_privilege
  end
end
