defmodule AlexClaw.Skills.BootChecksumTest do
  @moduledoc """
  A skill is loaded at boot only if its file is the file that was approved
  (skill_registry.ex:516–526).

  Approval — a person's TOTP code, or the containment check — is recorded
  with the file's SHA-256. At boot, a file whose content no longer matches is
  not loaded, whoever changed it and however it was approved, and the admin
  is told. This is the one check that keeps code nobody approved from running
  after a restart; until now no test pinned it.

  `SkillRegistry.reload_persisted/0` runs the same load as boot, so the state
  after a restart is reproduced without restarting (the pattern of
  containment_recheck_test.exs).
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.{RecordingGateway, Repo}
  alias AlexClaw.Skills.DynamicSkill
  alias AlexClaw.Workflows.SkillRegistry

  setup do
    skills_dir = Application.get_env(:alex_claw, :skills_dir)
    File.mkdir_p!(skills_dir)
    RecordingGateway.install()

    on_exit(fn ->
      SkillRegistry.unload_skill("checksum_probe")
      File.rm_rf!(skills_dir)
    end)

    %{skills_dir: skills_dir}
  end

  defp source(reply) do
    """
    defmodule AlexClaw.Skills.Dynamic.ChecksumProbe do
      @behaviour AlexClaw.Skill
      @impl true
      def version, do: "1.0.0"
      @impl true
      def description, do: "checksum probe"
      @impl true
      def run(_args), do: {:ok, #{inspect(reply)}, :on_success}
    end
    """
  end

  defp sha256(code), do: :crypto.hash(:sha256, code) |> Base.encode16(case: :lower)

  # The database records what was approved; the file on disk is what boot finds.
  defp persist(dir, approved_code, file_code, approval) do
    File.write!(Path.join(dir, "checksum_probe.ex"), file_code)

    {:ok, _} =
      %DynamicSkill{}
      |> DynamicSkill.changeset(%{
        name: "checksum_probe",
        module_name: "Elixir.AlexClaw.Skills.Dynamic.ChecksumProbe",
        file_path: "checksum_probe.ex",
        checksum: sha256(approved_code),
        permissions: [],
        routes: [],
        origin: "upload",
        approval: approval
      })
      |> Repo.insert()

    :ok
  end

  defp eventually(check, attempts \\ 50) do
    Enum.any?(1..attempts, fn _ -> check.() or (Process.sleep(20) && false) end)
  end

  test "the approved file is loaded", %{skills_dir: dir} do
    code = source("approved")
    :ok = persist(dir, code, code, "totp")

    :ok = SkillRegistry.reload_persisted()

    assert {:ok, AlexClaw.Skills.Dynamic.ChecksumProbe} = SkillRegistry.resolve("checksum_probe")
  end

  for approval <- ["totp", "containment"] do
    test "a #{approval}-approved file changed on disk is not loaded, and the admin is told",
         %{skills_dir: dir} do
      :ok = persist(dir, source("approved"), source("changed after approval"), unquote(approval))

      :ok = SkillRegistry.reload_persisted()

      assert {:error, :unknown_skill} = SkillRegistry.resolve("checksum_probe")

      # The notice goes out from a supervised task.
      assert eventually(fn ->
               Enum.any?(RecordingGateway.sent(), &(&1 =~ "checksum_probe"))
             end),
             "no notice named the skill: #{inspect(RecordingGateway.sent())}"

      [notice] = Enum.filter(RecordingGateway.sent(), &(&1 =~ "checksum_probe"))
      # The notice points where skills are managed: the admin UI. The chat
      # commands it used to suggest do not exist.
      assert notice =~ ~r/Admin UI/i
      refute notice =~ "/skill"
    end
  end

  test "a file that is missing is not loaded, and nothing crashes", %{skills_dir: dir} do
    code = source("approved")
    :ok = persist(dir, code, code, "totp")
    File.rm!(Path.join(dir, "checksum_probe.ex"))

    assert :ok = SkillRegistry.reload_persisted()
    assert {:error, :unknown_skill} = SkillRegistry.resolve("checksum_probe")
  end
end
