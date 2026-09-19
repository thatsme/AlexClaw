defmodule AlexClaw.Skills.DynamicSkillProvenanceTest do
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Repo
  alias AlexClaw.Skills.DynamicSkill
  alias AlexClaw.Workflows.SkillRegistry

  setup do
    skills_dir = Application.get_env(:alex_claw, :skills_dir)
    File.mkdir_p!(skills_dir)
    on_exit(fn -> File.rm_rf!(skills_dir) end)
    %{skills_dir: skills_dir}
  end

  defp write_skill(dir, name, version \\ "1.0.0") do
    File.write!(Path.join(dir, "#{name}.ex"), """
    defmodule AlexClaw.Skills.Dynamic.#{Macro.camelize(name)} do
      @behaviour AlexClaw.Skill
      @impl true
      def version, do: "#{version}"
      @impl true
      def description, do: "provenance probe"
      @impl true
      def run(_args), do: {:ok, "ok", :on_success}
    end
    """)

    "#{name}.ex"
  end

  defp record(name), do: Repo.get_by(DynamicSkill, name: name)

  describe "defaults" do
    test "a plain load records an uploaded, TOTP-approved skill", %{skills_dir: dir} do
      file = write_skill(dir, "prov_default")
      on_exit(fn -> SkillRegistry.unload_skill("prov_default") end)

      {:ok, _} = SkillRegistry.load_skill(file)

      assert %{origin: "upload", approval: "totp"} = record("prov_default")
    end
  end

  describe "explicit provenance" do
    test "a generated, containment-approved skill is recorded as such", %{skills_dir: dir} do
      file = write_skill(dir, "prov_generated")
      on_exit(fn -> SkillRegistry.unload_skill("prov_generated") end)

      {:ok, _} = SkillRegistry.load_skill(file, origin: "generated", approval: "containment")

      assert %{origin: "generated", approval: "containment"} = record("prov_generated")
    end

    test "a generated skill approved by TOTP is distinguishable", %{skills_dir: dir} do
      file = write_skill(dir, "prov_generated_totp")
      on_exit(fn -> SkillRegistry.unload_skill("prov_generated_totp") end)

      {:ok, _} = SkillRegistry.load_skill(file, origin: "generated", approval: "totp")

      assert %{origin: "generated", approval: "totp"} = record("prov_generated_totp")
    end
  end

  describe "reload re-establishes TOTP approval" do
    test "a containment-approved skill becomes TOTP-approved after reload", %{skills_dir: dir} do
      file = write_skill(dir, "prov_reload", "1.0.0")
      on_exit(fn -> SkillRegistry.unload_skill("prov_reload") end)

      {:ok, _} = SkillRegistry.load_skill(file, origin: "generated", approval: "containment")
      assert %{approval: "containment"} = record("prov_reload")

      write_skill(dir, "prov_reload", "1.1.0")
      {:ok, _} = SkillRegistry.reload_skill("prov_reload")

      # Reload is TOTP-gated at every call site, so it upgrades the approval.
      assert %{origin: "generated", approval: "totp"} = record("prov_reload")
    end
  end

  describe "changeset validation" do
    test "an unknown origin is rejected" do
      changeset =
        DynamicSkill.changeset(%DynamicSkill{}, %{
          name: "x",
          module_name: "M",
          file_path: "x.ex",
          checksum: "c",
          origin: "smuggled"
        })

      refute changeset.valid?
    end

    test "an unknown approval is rejected" do
      changeset =
        DynamicSkill.changeset(%DynamicSkill{}, %{
          name: "x",
          module_name: "M",
          file_path: "x.ex",
          checksum: "c",
          approval: "vibes"
        })

      refute changeset.valid?
    end
  end
end
