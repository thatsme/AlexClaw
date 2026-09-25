defmodule AlexClaw.GateCatalogueTest do
  @moduledoc """
  The one door: every privileged action, who may ask for it, and with what
  proof (reports/S5_ONE_DOOR.md §2–§4; THREAT_MODEL.md P2, P3; 0.4.0 S5a).

  `AlexClaw.ControlPlane` — already "the one path by which the control plane
  changes" (`gated/4`, used by every admin page) — grows into the one door
  for EVERY privileged action, rather than a second module beside it. It
  holds a CATALOGUE: for each named action, for each entry
  point (`:admin_ui`, `:gateway`, `:mcp`, `:skill`, `:webhook`, `:system`), the
  proof it requires — `:none`, `:elevation` (the 15-minute 2FA window), or
  `:code` (a per-action code) — or absent: that entry point may not ask at
  all.

  The expected table below IS the policy Alex decided (§3 with §4): the admin
  UI authors; chat and MCP operate. Changing who may do what means changing
  this table — deliberately, in a test.

  - `ControlPlane.authorize/2` decides: `:ok`, `{:error, :entry_point_not_allowed}`,
    or `{:error, :second_factor_required}`.
  - `ControlPlane.perform/3` authorizes, runs the action, and audits EVERY
    attempt — allowed or refused — naming the action and the entry point.
  - An action not in the catalogue is refused, never assumed allowed.

  (In this file `Gate` is an alias for `AlexClaw.ControlPlane`.)
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  import Ecto.Query

  alias AlexClaw.Auth.AuditEntry
  alias AlexClaw.ControlPlane, as: Gate
  alias AlexClaw.ControlPlane.Context

  @entry_points [:admin_ui, :gateway, :mcp, :skill, :webhook, :system]

  # action => %{entry_point => proof}. Entry points not listed may not ask.
  @expected %{
    # control plane
    save_workflow: %{admin_ui: :elevation},
    delete_workflow: %{admin_ui: :elevation},
    duplicate_workflow: %{admin_ui: :elevation},
    import_workflow: %{admin_ui: :elevation},
    save_step: %{admin_ui: :elevation},
    remove_step: %{admin_ui: :elevation},
    reorder_steps: %{admin_ui: :elevation},
    assign_resource: %{admin_ui: :elevation},
    save_resource: %{admin_ui: :elevation},
    delete_resource: %{admin_ui: :elevation},
    discover_resource: %{admin_ui: :elevation},
    set_setting: %{admin_ui: :elevation},
    load_skill: %{admin_ui: :elevation},
    unload_skill: %{admin_ui: :elevation},
    generate_skill: %{admin_ui: :elevation},
    save_provider: %{admin_ui: :elevation},
    save_policy: %{admin_ui: :elevation},
    save_node: %{admin_ui: :elevation},
    set_gateway_owner: %{admin_ui: :elevation},
    # secrets
    set_secret: %{admin_ui: :elevation},
    clear_secret: %{admin_ui: :elevation},
    attach_login: %{admin_ui: :elevation},
    generate_mcp_key: %{admin_ui: :elevation},
    connect_google: %{admin_ui: :elevation},
    disconnect_google: %{admin_ui: :elevation},
    upgrade_secrets: %{system: :none},
    # identity
    disable_second_factor: %{admin_ui: :code},
    regenerate_recovery_codes: %{admin_ui: :code},
    sign_out_everywhere: %{admin_ui: :elevation},
    # data
    download_database: %{admin_ui: :elevation},
    export_data: %{admin_ui: :elevation},
    export_workflow: %{admin_ui: :elevation},
    restore_data: %{admin_ui: :code},
    clear_run_history: %{admin_ui: :elevation},
    # runs
    run_workflow: %{admin_ui: :none, gateway: :none, mcp: :none, webhook: :none, system: :none},
    run_protected_workflow: %{admin_ui: :code, gateway: :code},
    run_skill: %{admin_ui: :none, gateway: :none, skill: :none, system: :none},
    run_privileged_skill: %{admin_ui: :elevation},
    # recordings
    record: %{admin_ui: :elevation},
    replay: %{admin_ui: :elevation}
  }

  describe "the catalogue is the decided policy" do
    test "it names exactly the actions of the expected table" do
      assert Enum.sort(Map.keys(Gate.catalogue())) == Enum.sort(Map.keys(@expected))
    end

    for {action, allowed} <- @expected, entry <- @entry_points do
      expected = Map.get(allowed, entry)

      test "#{action} from #{entry}: #{inspect(expected || :not_allowed)}" do
        assert Gate.catalogue()[unquote(action)][unquote(entry)] == unquote(expected)
      end
    end
  end

  describe "authorize/2 applies it" do
    defp context(entry, proof), do: Context.new(entry, "test", proof)

    for {action, allowed} <- @expected, entry <- @entry_points do
      case Map.get(allowed, entry) do
        nil ->
          test "#{action} from #{entry} is refused whatever the proof" do
            for proof <- [nil, :elevation, :code] do
              assert {:error, :entry_point_not_allowed} =
                       Gate.authorize(unquote(action), context(unquote(entry), proof))
            end
          end

        :none ->
          test "#{action} from #{entry} needs no second factor" do
            assert :ok = Gate.authorize(unquote(action), context(unquote(entry), nil))
          end

        needed ->
          test "#{action} from #{entry} needs #{needed}" do
            assert {:error, :second_factor_required} =
                     Gate.authorize(unquote(action), context(unquote(entry), nil))

            assert :ok = Gate.authorize(unquote(action), context(unquote(entry), unquote(needed)))
          end
      end
    end

    test "a code does not stand in for an elevation, nor an elevation for a code" do
      assert {:error, :second_factor_required} =
               Gate.authorize(:save_workflow, context(:admin_ui, :code))

      assert {:error, :second_factor_required} =
               Gate.authorize(:restore_data, context(:admin_ui, :elevation))
    end

    test "an action not in the catalogue is refused" do
      assert {:error, :unknown_action} =
               Gate.authorize(:launch_missiles, context(:admin_ui, :elevation))
    end
  end

  # perform/3 takes a VERIFIED context: Context.admin_ui(sid) reads that
  # session's elevation itself. A caller cannot claim a proof it does not
  # have (Context.new/3, with a proof atom, is for authorize/2's pure
  # decision tests only — perform/3 refuses a context not built from facts).
  describe "perform/3 audits every attempt" do
    setup do
      sid = AlexClaw.Auth.Elevation.new_sid()

      on_exit(fn ->
        AlexClaw.SandboxCleanup.run(fn -> AlexClaw.Auth.Elevation.revoke(sid) end)
      end)

      %{sid: sid}
    end

    defp audited(fragment) do
      Repo.all(from(e in AuditEntry, where: like(e.reason, ^"%#{fragment}%")))
    end

    test "an allowed action: an allow row naming the action and the entry point", %{sid: sid} do
      {:ok, _} = AlexClaw.Auth.Elevation.grant(sid)
      name = "gate-audit-#{System.unique_integer([:positive])}"

      assert {:ok, _workflow} =
               Gate.perform(:save_workflow, %{attrs: %{name: name}}, Context.admin_ui(sid))

      assert Enum.any?(
               audited("save_workflow"),
               &(&1.decision in ["allow", "write"] and &1.reason =~ "admin_ui")
             )
    end

    test "without the elevation: refused, a deny row, and the action did not happen", %{sid: sid} do
      name = "gate-noelev-#{System.unique_integer([:positive])}"

      assert {:error, :second_factor_required} =
               Gate.perform(:save_workflow, %{attrs: %{name: name}}, Context.admin_ui(sid))

      assert Enum.any?(audited("save_workflow"), &(&1.decision == "deny"))
      refute Repo.exists?(from(w in AlexClaw.Workflows.Workflow, where: w.name == ^name))
    end

    test "from an entry point that may not ask: refused, a deny row, nothing happened" do
      name = "gate-refused-#{System.unique_integer([:positive])}"

      assert {:error, :entry_point_not_allowed} =
               Gate.perform(:save_workflow, %{attrs: %{name: name}}, Context.gateway("chat-1"))

      assert Enum.any?(
               audited("save_workflow"),
               &(&1.decision == "deny" and &1.reason =~ "gateway")
             )

      refute Repo.exists?(from(w in AlexClaw.Workflows.Workflow, where: w.name == ^name))
    end

    test "a context that merely claims a proof is refused" do
      name = "gate-forged-#{System.unique_integer([:positive])}"

      assert {:error, _} =
               Gate.perform(
                 :save_workflow,
                 %{attrs: %{name: name}},
                 Context.new(:admin_ui, "forger", :elevation)
               )

      refute Repo.exists?(from(w in AlexClaw.Workflows.Workflow, where: w.name == ^name))
    end
  end
end
