defmodule AlexClaw.Resources.ApiDiscoveryOutcomeTest do
  @moduledoc """
  Discovery writes what it found to the resource from a task started after
  the change that asked for it. That write and its outcome row are one
  transaction, recorded under the requester carried into the task — the
  session by fingerprint and the principal — not under whatever the task's
  own process would say.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.{AuditEntry, Elevation}
  alias AlexClaw.{ControlPlane, Resources}
  alias AlexClaw.Resources.ApiDiscovery

  describe "a discovery that runs" do
    setup do
      bypass = Bypass.open()

      # Any path: a HEAD that answers, and no OpenAPI document anywhere.
      Bypass.expect(bypass, fn conn -> Plug.Conn.resp(conn, 404, "") end)

      {:ok, resource} =
        Resources.create_resource(
          %{name: "discovery-probe", type: "api", url: "http://localhost:#{bypass.port}/api"},
          skip_discovery: true
        )

      {:ok, resource: resource}
    end

    defp outcome_rows(resource) do
      Repo.all(
        from(e in AuditEntry,
          where:
            e.decision == "outcome" and
              like(e.reason, ^"resource discovery: %(id #{resource.id})%")
        )
      )
    end

    test "the completion write is recorded under the requester that asked", %{resource: resource} do
      {:ok, _pid} =
        ApiDiscovery.run_async(resource, %{session: "fp-discoverer", principal: "delegate"})

      AlexClaw.TaskDrain.drain(timeout: 15_000)

      assert [row] = outcome_rows(resource)
      assert row.caller == "admin:fp-discoverer"
      # Not "owner": the principal the task carried, not the one it would compute.
      assert row.principal == "delegate"
      assert row.reason =~ "completed"

      {:ok, fresh} = Resources.get_resource(resource.id)
      assert fresh.metadata["discovery"]["status"] == "completed"
    end

    test "work nobody asked for from a session is recorded as unattended", %{resource: resource} do
      {:ok, _pid} = ApiDiscovery.run_async(resource)
      AlexClaw.TaskDrain.drain(timeout: 15_000)

      assert [row] = outcome_rows(resource)
      assert row.caller == "admin:" <> ControlPlane.unattended().session
    end
  end

  test "a page's requester names the session by fingerprint, never the sid" do
    sid = Elevation.new_sid()
    requester = ControlPlane.requester(sid)

    assert requester.session == Elevation.fingerprint(sid)
    refute requester.session =~ sid
  end
end
