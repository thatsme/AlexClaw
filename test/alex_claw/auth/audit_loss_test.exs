defmodule AlexClaw.Auth.AuditLossTest do
  @moduledoc """
  A lost audit row is logged at error level with the whole event, and the
  operator is told over the gateways: the first loss at once, later ones
  counted and announced together at most once per interval.

  Throttling is tested on a private notifier with a short interval, so the
  timing is the test's and not the application's. Gateways are global, so this
  does not run beside anything else — and a notice from another part of the
  application can still arrive during a test (seed 217703: the config
  loader's "read-only until 2FA" notice). So these tests count only audit
  notices, never everything the gateway received.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  import ExUnit.CaptureLog

  alias AlexClaw.Auth.{AuditEntry, AuditLog, AuditLoss, AuthContext}
  alias AlexClaw.RecordingGateway

  @interval 150

  setup do
    RecordingGateway.install()
    :ok
  end

  defp start_notifier do
    name = :"audit_loss_#{System.unique_integer([:positive])}"
    start_supervised!({AuditLoss, name: name, interval: @interval})
    name
  end

  defp lose(server, n \\ 1) do
    capture_log(fn ->
      for i <- 1..n, do: AuditLoss.lost(%{reason: "loss #{i}"}, :db_down, server)
    end)
  end

  # Only the notices this module is about; anything else the gateway carried
  # during the test belongs to someone else.
  defp audit_sent do
    Enum.filter(RecordingGateway.sent(), &(&1 =~ ~r/audit rows? could not be written/))
  end

  # Notices leave through a supervised task, so they arrive shortly after.
  defp notices(count, deadline \\ 1_000) do
    case audit_sent() do
      sent when length(sent) >= count or deadline <= 0 ->
        sent

      _ ->
        Process.sleep(10)
        notices(count, deadline - 10)
    end
  end

  describe "a lost row in AuditLog" do
    # A changeset that refuses the row: the one failure that used to make no
    # sound at all.
    test "is logged at error level with the full event, and not written" do
      ctx = %AuthContext{
        caller: "refused_skill",
        caller_type: nil,
        permission: :llm,
        workflow_run_id: nil,
        chain_depth: 0,
        timestamp: DateTime.utc_now(),
        token: nil
      }

      log =
        capture_log([level: :error], fn -> assert AuditLog.log_deny(ctx, "unrecorded") == :ok end)

      assert log =~ "[error]"
      assert log =~ "Audit row lost"
      assert log =~ "caller_type"
      assert log =~ ~s(reason: "unrecorded")
      assert log =~ ~s(caller: "\\"refused_skill\\"")
      refute Repo.exists?(from(e in AuditEntry, where: e.reason == "unrecorded"))
    end
  end

  describe "the notice" do
    test "the first loss is announced at once" do
      server = start_notifier()
      lose(server)

      assert [notice] = notices(1)
      assert notice =~ "An audit row could not be written"
    end

    test "losses after the first are held, then announced together with their count" do
      server = start_notifier()
      lose(server)
      assert [_first] = notices(1)

      lose(server, 3)
      Process.sleep(div(@interval, 3))
      assert length(audit_sent()) == 1, "a held loss was announced early"

      assert [_first, summary] = notices(2)
      assert summary =~ "3 more audit rows could not be written"
    end

    test "after a quiet interval, the next loss is announced at once again" do
      server = start_notifier()
      lose(server)
      assert [_first] = notices(1)

      # One interval with nothing held returns to idle.
      Process.sleep(@interval * 2)
      assert length(audit_sent()) == 1

      lose(server)
      assert [_first, again] = notices(2, 50)
      assert again =~ "An audit row could not be written"
    end

    test "a flood produces one notice per interval, not one per row" do
      server = start_notifier()
      lose(server, 200)

      Process.sleep(@interval + div(@interval, 2))
      assert length(audit_sent()) == 2
    end

    test "with no notifier running, the loss is still logged and the caller unharmed" do
      log =
        capture_log([level: :error], fn ->
          assert AuditLoss.lost(%{reason: "nobody listening"}, :db_down, :no_such_notifier) == :ok
        end)

      assert log =~ "Audit row lost"
      assert log =~ "nobody listening"
    end
  end
end
