defmodule AlexClaw.Skills.SkillAPITest do
  use AlexClaw.DataCase

  alias AlexClaw.Skills.SkillAPI
  alias AlexClaw.Workflows.SkillRegistry

  describe "permission enforcement" do
    setup do
      skills_dir = Application.get_env(:alex_claw, :skills_dir)
      File.mkdir_p!(skills_dir)

      # Create a skill with only :config_read permission
      source = """
      defmodule AlexClaw.Skills.Dynamic.LimitedSkill do
        @behaviour AlexClaw.Skill
        @impl true
        def permissions, do: [:config_read]
        @impl true
        def run(_args), do: {:ok, "limited"}
      end
      """

      File.write!(Path.join(skills_dir, "limited_skill.ex"), source)
      {:ok, _} = SkillRegistry.load_skill("limited_skill.ex")

      on_exit(fn ->
        SkillRegistry.unload_skill("limited_skill")
        File.rm_rf!(skills_dir)
      end)

      %{module: AlexClaw.Skills.Dynamic.LimitedSkill}
    end

    test "allows declared permissions", %{module: mod} do
      assert {:ok, _} = SkillAPI.config_get(mod, "some.key", "default")
    end

    test "denies undeclared permissions", %{module: mod} do
      assert {:error, :permission_denied} = SkillAPI.llm_complete(mod, "test prompt")
      assert {:error, :permission_denied} = SkillAPI.send_telegram(mod, "test")
      assert {:error, :permission_denied} = SkillAPI.memory_search(mod, "query")
      assert {:error, :permission_denied} = SkillAPI.memory_store(mod, :test, "content")
      assert {:error, :permission_denied} = SkillAPI.memory_exists?(mod, "test")
      assert {:error, :permission_denied} = SkillAPI.memory_recent(mod)
      assert {:error, :permission_denied} = SkillAPI.http_get(mod, "https://example.com")
      assert {:error, :permission_denied} = SkillAPI.http_post(mod, "https://example.com")
      assert {:error, :permission_denied} = SkillAPI.list_resources(mod)
      assert {:error, :permission_denied} = SkillAPI.run_skill(mod, "rss_collector", %{})
    end

    test "core skills pass all permission checks" do
      # Core skills have :all permissions
      assert {:ok, _} = SkillAPI.config_get(AlexClaw.Skills.RSSCollector, "some.key", "default")
    end

    test "unknown module is denied" do
      assert {:error, :permission_denied} = SkillAPI.config_get(FakeModule, "key")
    end
  end

  describe "known_permissions/0" do
    test "returns all known permission atoms" do
      perms = SkillAPI.known_permissions()
      assert is_list(perms)
      assert :llm in perms
      assert :web_read in perms
      assert :telegram_send in perms
      assert :memory_read in perms
      assert :memory_write in perms
      assert :config_read in perms
      assert :resources_read in perms
      assert :skill_invoke in perms
    end
  end
end
