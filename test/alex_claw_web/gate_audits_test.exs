defmodule AlexClawWeb.GateAuditsTest do
  @moduledoc """
  What leaves no trace today, and what leaves on a login alone
  (reports/S5_INVENTORY.md §8 items 7, 13, 14, 18, and "Login and logout write
  no audit row"; THREAT_MODEL.md P8; 0.4.0 S5a).

  - Data downloads (the full database dump, the data export, a workflow
    export) need the elevation, and each download is audited. Without it: 403
    and a deny row.
  - Clearing run history needs the elevation and is audited.
  - Every run start writes an audit row naming the workflow and the entry
    point.
  - Login (success and failure) and logout are audited — never the password.
  - `Secrets.define/1` and `Secrets.rebind/2` are audited.
  """
  use AlexClawWeb.ConnCase, async: false
  @moduletag :integration

  import Ecto.Query

  alias AlexClaw.Auth.{AuditEntry, Elevation}
  alias AlexClaw.{Repo, Workflows}

  setup %{conn: conn} do
    sid = Elevation.new_sid()
    on_exit(fn -> AlexClaw.SandboxCleanup.run(fn -> Elevation.revoke(sid) end) end)
    {:ok, conn: conn, sid: sid}
  end

  defp rows(decision, fragment) do
    Repo.all(
      from(e in AuditEntry, where: e.decision == ^decision and like(e.reason, ^"%#{fragment}%"))
    )
  end

  defp any_row(fragment) do
    Repo.all(from(e in AuditEntry, where: like(e.reason, ^"%#{fragment}%")))
  end

  describe "data downloads need the elevation, and are audited" do
    for path <- ["/database/download", "/database/export"] do
      test "#{path} without the elevation: 403 and a deny row", %{conn: conn, sid: sid} do
        conn = conn |> authenticate(sid) |> get(unquote(path))

        assert conn.status == 403
        assert rows("deny", "download") != [] or rows("deny", "export") != []
      end
    end

    test "/database/export with it: served, and audited", %{conn: conn, sid: sid} do
      {:ok, _} = Elevation.grant(sid)
      conn = conn |> authenticate(sid) |> get("/database/export")

      assert conn.status == 200
      assert any_row("export") |> Enum.any?(&(&1.decision in ["allow", "write", "outcome"]))
    end

    test "a workflow export without the elevation: 403", %{conn: conn, sid: sid} do
      {:ok, wf} =
        Workflows.create_workflow(%{name: "Export #{System.unique_integer([:positive])}"})

      conn = conn |> authenticate(sid) |> get("/workflows/#{wf.id}/export")

      assert conn.status == 403
    end
  end

  describe "clearing run history" do
    test "without the elevation it is refused; nothing is deleted", %{conn: conn, sid: sid} do
      {:ok, wf} = Workflows.create_workflow(%{name: "Runs #{System.unique_integer([:positive])}"})
      {:ok, _run} = Workflows.create_run(wf)

      {:ok, view, _html} = conn |> authenticate(sid) |> live("/workflows/#{wf.id}/runs")
      render_click(view, "clear_runs", %{})

      assert Repo.aggregate(AlexClaw.Workflows.WorkflowRun, :count) >= 1
      assert rows("deny", "clear_run_history") != []
    end
  end

  describe "run starts are audited" do
    test "a run started from the admin UI names the workflow and the entry point" do
      # The run executes in its own process: share the test's connection with it.
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      {:ok, wf} =
        Workflows.create_workflow(%{
          name: "Audited run #{System.unique_integer([:positive])}",
          enabled: true
        })

      sid = Elevation.new_sid()

      assert {:ok, _} =
               AlexClaw.ControlPlane.perform(
                 :run_workflow,
                 %{workflow_id: wf.id},
                 AlexClaw.ControlPlane.Context.admin_ui(sid)
               )

      assert Enum.any?(
               any_row("run_workflow"),
               &(&1.reason =~ wf.name and &1.reason =~ "admin_ui")
             )

      # Wait for the run to finish before the test ends: a run still working
      # when the sandbox closes is what logged "checked in the connection owned
      # by Task.Supervised".
      finished? = fn ->
        Repo.exists?(
          from(r in AlexClaw.Workflows.WorkflowRun,
            where: r.workflow_id == ^wf.id and r.status != "running"
          )
        )
      end

      assert Enum.any?(1..100, fn _ -> finished?.() or (Process.sleep(50) && false) end),
             "the run did not finish"
    end
  end

  describe "login and logout" do
    test "a failed login is audited, never with the password", %{conn: conn} do
      post(conn, "/login", %{"password" => "wrong-password-xyz"})

      entries = any_row("login")
      assert Enum.any?(entries, &(&1.decision == "deny"))
      refute inspect(entries) =~ "wrong-password-xyz"
    end

    test "a successful login is audited", %{conn: conn} do
      password = Application.fetch_env!(:alex_claw, :admin_password)
      post(conn, "/login", %{"password" => password})

      assert Enum.any?(any_row("login"), &(&1.decision in ["allow", "outcome"]))
      refute inspect(any_row("login")) =~ password
    end
  end

  describe "secrets catalogue changes" do
    @describetag :vault

    test "define and rebind are audited" do
      name = "audit_define_#{System.unique_integer([:positive])}"

      {:ok, _} =
        AlexClaw.Secrets.define(%{name: name, kind: "api_token", binding: ["host:a.example"]})

      :ok = AlexClaw.Secrets.rebind(name, ["host:b.example"])

      entries = any_row(name)
      assert Enum.any?(entries, &(&1.reason =~ ~r/defin/i))
      assert Enum.any?(entries, &(&1.reason =~ ~r/rebind|bound/i))
    end
  end
end
