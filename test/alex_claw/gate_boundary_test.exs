defmodule AlexClaw.GateBoundaryTest do
  @moduledoc """
  Nothing reaches a privileged action except through `AlexClaw.ControlPlane`
  (reports/S5_ONE_DOOR.md §2; THREAT_MODEL.md P2; 0.4.0 S5a).

  The privileged functions are the ones reports/S5_INVENTORY.md lists (§1–§6).
  An entry point that calls one directly bypasses the catalogue, the second
  factor and the audit — exactly how the holes in the inventory came about.

  S5a scans the admin UI (LiveViews and their components) and the web
  controllers. S5b adds the gateway dispatcher, MCP and SkillAPI, as their
  surfaces are cut down.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  # Module => the functions on it that perform a privileged action.
  @privileged %{
    "Workflows" =>
      ~w(create_workflow update_workflow delete_workflow duplicate_workflow import_workflow
         add_step update_step remove_step reorder_steps assign_resource unassign_resource
         clear_runs export_workflow),
    "Resources" => ~w(create_resource update_resource delete_resource discover),
    "Config" => ~w(set persist delete remove clear),
    "SkillRegistry" =>
      ~w(load_skill unload_skill reload_skill promote_pending write_pending stage_upload),
    "LLM" => ~w(create_provider update_provider delete_provider),
    "Cluster" => ~w(create_node update_node delete_node),
    "Secrets" => ~w(define put_value delete rebind),
    "TOTP" => ~w(setup confirm_setup disable disable_by),
    "RecoveryCodes" => ~w(generate),
    "Sessions" => ~w(remove_all),
    "Restore" => ~w(run load),
    "DataExport" => ~w(write),
    "Key" => ~w(generate revoke),
    "OAuth" => ~w(exchange_code disconnect),
    "WebAutomation" => ~w(record play stop_recording),
    "Executor" => ~w(run launch),
    "Launch" => ~w(start),
    "Recording" => ~w(attach_login)
  }

  @entry_points ["lib/alex_claw_web/live/**/*.ex", "lib/alex_claw_web/controllers/**/*.ex"]

  defp pattern do
    alternatives =
      for {mod, funs} <- @privileged, fun <- funs, do: "#{mod}\\.#{fun}\\("

    # Direct Repo writes from an entry point are a bypass too (policies.ex did it).
    Regex.compile!(
      "\\b(" <> Enum.join(alternatives ++ ["Repo\\.(insert|update|delete)"], "|") <> ")"
    )
  end

  defp files, do: Enum.flat_map(@entry_points, &Path.wildcard/1)

  test "the scan covers the admin UI and the controllers (no vacuous pass)" do
    found = files()
    assert length(found) > 10, "the scan found almost no files: #{inspect(found)}"
    assert Enum.any?(found, &String.ends_with?(&1, "live/admin_live/workflows.ex"))
    assert Enum.any?(found, &String.ends_with?(&1, "controllers/database_controller.ex"))
  end

  test "the pattern recognises what it is for" do
    re = pattern()
    assert Regex.match?(re, "Workflows.create_workflow(attrs)")
    assert Regex.match?(re, "Config.persist(key, value, opts)")
    assert Regex.match?(re, "Repo.insert(changeset)")
    refute Regex.match?(re, "Workflows.get_workflow(id)")
    refute Regex.match?(re, "Config.get(key)")
  end

  test "no entry point calls a privileged function directly" do
    re = pattern()

    offenders =
      for path <- files(),
          {line, n} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          not String.starts_with?(String.trim_leading(line), "#"),
          Regex.match?(re, line),
          do: "#{path}:#{n}: #{String.trim(line)}"

    assert offenders == [],
           "entry points reaching privileged code without ControlPlane:\n" <>
             Enum.join(offenders, "\n")
  end
end
