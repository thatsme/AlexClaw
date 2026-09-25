defmodule AlexClaw.GateBoundaryTest do
  @moduledoc """
  Nothing reaches a privileged action except through `AlexClaw.ControlPlane`
  (reports/S5_ONE_DOOR.md §2; THREAT_MODEL.md P2; 0.4.0 S5a).

  The privileged functions are the ones reports/S5_INVENTORY.md lists (§1–§6).
  An entry point that calls one directly bypasses the catalogue, the second
  factor and the audit — exactly how the holes in the inventory came about.

  S5a scanned the admin UI (LiveViews and their components) and the web
  controllers. S5b adds the gateway dispatcher, the gateways, MCP and SkillAPI:
  they may still RUN things, but only by asking ControlPlane (run_workflow,
  run_protected_workflow, run_skill).
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
    "Executor" => ~w(run launch run_with_initial_input run_remote_trigger),
    "Launch" => ~w(start),
    "Recording" => ~w(attach_login)
  }

  @entry_points [
    "lib/alex_claw_web/live/**/*.ex",
    "lib/alex_claw_web/controllers/**/*.ex",
    # S5b
    "lib/alex_claw/dispatcher.ex",
    "lib/alex_claw/dispatcher/**/*.ex",
    "lib/alex_claw/gateway/**/*.ex",
    "lib/alex_claw/mcp/**/*.ex",
    "lib/alex_claw/skills/skill_api.ex",
    # S5c: another node's requests arrive here
    "lib/alex_claw/cluster/**/*.ex"
  ]

  defp pattern do
    alternatives =
      for {mod, funs} <- @privileged, fun <- funs, do: "#{mod}\\.#{fun}\\("

    # Direct Repo writes from an entry point are a bypass too (policies.ex did it).
    Regex.compile!(
      "\\b(" <> Enum.join(alternatives ++ ["Repo\\.(insert|update|delete)"], "|") <> ")"
    )
  end

  # Files under an entry-point path that are not entry points, by name, each
  # with its reason. The MCP key's module is the key's IMPLEMENTATION — the
  # admin UI reaches it through ControlPlane (generate_mcp_key) — not a door
  # an MCP client can knock on.
  @not_entry_points %{
    "lib/alex_claw/mcp/key.ex" =>
      "The MCP key's implementation, reached only through ControlPlane (generate_mcp_key)."
  }

  defp files do
    @entry_points
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.reject(&(&1 in Map.keys(@not_entry_points)))
  end

  test "every file excluded by name still exists (no stale exclusion)" do
    for {path, reason} <- @not_entry_points do
      assert File.exists?(path), "#{path} is excluded and does not exist (#{reason})"
    end
  end

  test "the scan covers every entry point (no vacuous pass)" do
    found = files()
    assert length(found) > 10, "the scan found almost no files: #{inspect(found)}"

    for expected <- [
          "live/admin_live/workflows.ex",
          "controllers/database_controller.ex",
          "lib/alex_claw/dispatcher.ex",
          "dispatcher/auth_commands.ex",
          "mcp/server.ex",
          "skills/skill_api.ex"
        ] do
      assert Enum.any?(found, &String.ends_with?(&1, expected)), "the scan misses #{expected}"
    end
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
