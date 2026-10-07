defmodule AlexClaw.ConnectionsTargetDoorTest do
  @moduledoc """
  The name lookup that keeps a connection away from AlexClaw's own services
  happens before the save's transaction, at the control plane's door —
  never inside it, where a slow resolver would hold the transaction open
  (reports/SQLREAD_FIX_REVIEW.md F8). The changeset keeps a check that needs
  no lookup: address literals and `localhost`. The pool checks again before
  every connect.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :vault

  alias AlexClaw.Auth.Elevation
  alias AlexClaw.{Config, ControlPlane, SandboxCleanup}
  alias AlexClaw.Connections.{Connection, Pools}
  alias AlexClaw.ControlPlane.Context

  defp attrs(host) do
    repo = Application.fetch_env!(:alex_claw, AlexClaw.Repo)

    %{
      name: "door_#{System.unique_integer([:positive])}",
      host: host,
      port: repo[:port] || 5432,
      database: repo[:database],
      username: repo[:username],
      tls_mode: "disable",
      password: repo[:password]
    }
  end

  setup do
    sid = Elevation.new_sid()
    on_exit(fn -> SandboxCleanup.run(fn -> Elevation.revoke(sid) end) end)
    on_exit(fn -> Pools.stop_all() end)
    Config.set("auth.totp.enabled", "true", type: "boolean", category: "auth")
    {:ok, _} = Elevation.grant(sid)
    %{sid: sid}
  end

  test "the changeset does no lookup: a name is not resolved there" do
    assert Connection.changeset(%Connection{}, attrs("openbao-test")).valid?
  end

  test "the changeset still refuses address literals and localhost" do
    for host <- ["127.0.0.1", "localhost", "10.213.64.2", "::1"] do
      refute Connection.changeset(%Connection{}, attrs(host)).valid?, host
    end
  end

  test "the control plane resolves the name before the transaction and refuses an internal one",
       %{sid: sid} do
    params = %{connection: nil, attrs: attrs("openbao-test"), detail: "connection saved"}

    assert {:error, {:internal_target, why}} =
             ControlPlane.perform(:save_connection, params, Context.admin_ui(sid))

    assert why =~ "AlexClaw's own"
  end

  test "a customer's server passes the door", %{sid: sid} do
    host = Application.fetch_env!(:alex_claw, AlexClaw.Repo)[:hostname]
    params = %{connection: nil, attrs: attrs(host), detail: "connection saved"}

    assert {:ok, %Connection{}} =
             ControlPlane.perform(:save_connection, params, Context.admin_ui(sid))
  end
end
