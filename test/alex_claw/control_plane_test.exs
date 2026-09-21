defmodule AlexClaw.ControlPlaneTest do
  @moduledoc """
  A control-plane change and its audit row are one transaction, behind an
  elevation, with effects outside the database only after commit.

  Elevation and configuration are global, so this does not run beside
  anything else.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  import ExUnit.CaptureLog

  alias AlexClaw.Auth.{AuditEntry, Elevation, Policy}
  alias AlexClaw.ControlPlane

  setup do
    sid = Elevation.new_sid()
    on_exit(fn -> Elevation.revoke(sid) end)
    {:ok, sid: sid}
  end

  defp configure_second_factor do
    AlexClaw.Config.set("auth.totp.secret", Base.encode32(NimbleTOTP.secret(), padding: false),
      type: "string",
      category: "auth",
      sensitive: true
    )

    AlexClaw.Config.set("auth.totp.enabled", "true", type: "boolean", category: "auth")
  end

  defp elevate(sid) do
    configure_second_factor()
    {:ok, _} = Elevation.grant(sid)
  end

  defp insert_policy(name) do
    %Policy{}
    |> Policy.changeset(%{name: name, rule_type: "rate_limit", config: %{}})
    |> Repo.insert()
  end

  defp rows(decision, detail) do
    Repo.all(
      from(e in AuditEntry, where: e.decision == ^decision and like(e.reason, ^"%#{detail}%"))
    )
  end

  defp policy?(name), do: Repo.exists?(from(p in Policy, where: p.name == ^name))

  describe "without an elevation" do
    test "nothing runs, and the refusal is audited", %{sid: sid} do
      configure_second_factor()

      assert ControlPlane.gated(sid, "cp: refused", fn -> send(self(), :ran) end) ==
               {:error, :not_elevated}

      refute_received :ran
      assert [_row] = rows("deny", "cp: refused")
    end

    test "with no second factor at all, the refusal says so", %{sid: sid} do
      assert ControlPlane.gated(sid, "cp: no factor", fn -> {:ok, :x} end) ==
               {:error, :no_second_factor}

      assert [row] = rows("deny", "cp: no factor")
      assert row.reason =~ "no_second_factor"
    end

    test "a session with no sid is refused", _ do
      configure_second_factor()
      assert ControlPlane.gated(nil, "cp: no sid", fn -> {:ok, :x} end) == {:error, :not_elevated}
    end
  end

  describe "with an elevation" do
    setup %{sid: sid} do
      elevate(sid)
      :ok
    end

    test "the change and its row are committed together", %{sid: sid} do
      assert {:ok, %Policy{name: "cp-committed"}} =
               ControlPlane.gated(sid, "cp: committed", fn -> insert_policy("cp-committed") end)

      assert policy?("cp-committed")
      assert [row] = rows("write", "cp: committed")
      assert row.caller == "admin:" <> Elevation.fingerprint(sid)
    end

    test "a change that fails takes its row with it", %{sid: sid} do
      result =
        ControlPlane.gated(sid, "cp: failed", fn ->
          {:ok, _} = insert_policy("cp-failed")
          {:error, :changed_my_mind}
        end)

      assert result == {:error, :changed_my_mind}
      refute policy?("cp-failed")
      assert rows("write", "cp: failed") == []
    end

    test "a change that raises takes its row with it", %{sid: sid} do
      assert_raise RuntimeError, "boom", fn ->
        ControlPlane.gated(sid, "cp: raised", fn ->
          {:ok, _} = insert_policy("cp-raised")
          raise "boom"
        end)
      end

      refute policy?("cp-raised")
      assert rows("write", "cp: raised") == []
    end

    # PostgreSQL text cannot hold a NUL byte, so this row genuinely cannot be
    # written: the change must not happen, and the loss must be loud.
    test "a row that cannot be written refuses the change", %{sid: sid} do
      log =
        capture_log([level: :error], fn ->
          result =
            ControlPlane.gated(sid, "cp: unwritable \0", fn ->
              send(self(), :ran)
              insert_policy("cp-unwritable")
            end)

          assert result == {:error, :audit_failed}
        end)

      refute_received :ran
      refute policy?("cp-unwritable")
      assert log =~ "Audit row lost"
    end

    test "after_commit receives the committed result", %{sid: sid} do
      {:ok, policy} =
        ControlPlane.gated(sid, "cp: after", fn -> insert_policy("cp-after") end, fn result ->
          send(self(), {:after, result})
        end)

      assert_received {:after, ^policy}
    end

    # The sandbox shares one connection, so "visible from another process"
    # proves nothing here. What proves the effect ran after commit is that it
    # failing cannot undo the change.
    test "after_commit runs outside the transaction: its failure does not undo the change",
         %{sid: sid} do
      assert_raise RuntimeError, "publish failed", fn ->
        ControlPlane.gated(sid, "cp: after raises", fn -> insert_policy("cp-kept") end, fn _ ->
          raise "publish failed"
        end)
      end

      assert policy?("cp-kept")
      assert [_row] = rows("write", "cp: after raises")
    end

    test "after_commit does not run when the change does not happen", %{sid: sid} do
      ControlPlane.gated(sid, "cp: no after", fn -> {:error, :no} end, fn _ ->
        send(self(), :after)
      end)

      refute_received :after
    end
  end

  describe "outcome/3" do
    test "records what happened, with the write that follows from it", %{sid: sid} do
      assert {:ok, _} =
               ControlPlane.outcome(sid, "cp: node answered", fn ->
                 insert_policy("cp-outcome")
               end)

      assert [_row] = rows("outcome", "cp: node answered")
      assert policy?("cp-outcome")
    end

    test "records the outcome alone when nothing follows from it", %{sid: sid} do
      assert {:ok, :recorded} = ControlPlane.outcome(sid, "cp: node silent")
      assert [_row] = rows("outcome", "cp: node silent")
    end

    test "a failed follow-up write takes the outcome row with it", %{sid: sid} do
      assert ControlPlane.outcome(sid, "cp: outcome failed", fn -> {:error, :gone} end) ==
               {:error, :gone}

      assert rows("outcome", "cp: outcome failed") == []
    end
  end
end
