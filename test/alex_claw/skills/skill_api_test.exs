defmodule AlexClaw.Skills.SkillAPITest do
  use AlexClaw.DataCase
  @moduletag :integration

  alias AlexClaw.Auth.SafeExecutor
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
      AlexClaw.Config.set("some.key", "value", type: "string", category: "test")

      assert {:ok, "value"} =
               SafeExecutor.as_skill(mod, fn ->
                 SkillAPI.config_get(mod, "some.key", "default")
               end)
    end

    # :config_read grants configuration, not credentials.
    # S9: the key is not named like a credential — since S7 such a key is
    # refused at save, which left this test passing on an unknown key.
    test "refuses a sensitive setting even with :config_read", %{module: mod} do
      {:ok, _} =
        AlexClaw.Config.set("test.private_value", "s3cret",
          type: "string",
          category: "test",
          sensitive: true
        )

      assert {:error, :sensitive} =
               SafeExecutor.as_skill(mod, fn -> SkillAPI.config_get(mod, "test.private_value") end)
    end

    test "denies undeclared permissions", %{module: mod} do
      assert {:error, :permission_denied} =
               SafeExecutor.as_skill(mod, fn -> SkillAPI.llm_complete(mod, "test prompt") end)

      assert {:error, :permission_denied} =
               SafeExecutor.as_skill(mod, fn -> SkillAPI.send_telegram(mod, "test") end)

      assert {:error, :permission_denied} =
               SafeExecutor.as_skill(mod, fn -> SkillAPI.memory_search(mod, "query") end)

      assert {:error, :permission_denied} =
               SafeExecutor.as_skill(mod, fn -> SkillAPI.memory_store(mod, :test, "content") end)

      assert {:error, :permission_denied} =
               SafeExecutor.as_skill(mod, fn -> SkillAPI.memory_exists?(mod, "test") end)

      assert {:error, :permission_denied} =
               SafeExecutor.as_skill(mod, fn -> SkillAPI.memory_recent(mod) end)

      assert {:error, :permission_denied} =
               SafeExecutor.as_skill(mod, fn -> SkillAPI.http_get(mod, "https://example.com") end)

      assert {:error, :permission_denied} =
               SafeExecutor.as_skill(mod, fn -> SkillAPI.http_post(mod, "https://example.com") end)

      assert {:error, :permission_denied} =
               SafeExecutor.as_skill(mod, fn -> SkillAPI.list_resources(mod) end)

      assert {:error, :permission_denied} =
               SafeExecutor.as_skill(mod, fn -> SkillAPI.run_skill(mod, "rss_collector", %{}) end)
    end

    # S9 (S8 C1): the fast path is for the core skill that is running, never
    # for a module a call merely names. This test used to call SkillAPI naming
    # a core module from anywhere, which pinned the hole.
    test "a running core skill passes all permission checks", %{module: mod} do
      AlexClaw.Config.set("some.key", "value", type: "string", category: "test")
      core = AlexClaw.Skills.RSSCollector

      assert {:ok, _} =
               SafeExecutor.as_skill(core, fn ->
                 SkillAPI.config_get(core, "some.key", "default")
               end)

      assert {:error, :permission_denied} =
               SafeExecutor.as_skill(mod, fn ->
                 SkillAPI.config_get(core, "some.key", "default")
               end),
             "a dynamic skill naming a core skill got its rights"

      assert {:error, :permission_denied} = SkillAPI.config_get(core, "some.key", "default"),
             "code that is not a running skill got a core skill's rights"
    end

    # The redaction is about the route, not the caller: a core skill needing a
    # credential reads Config directly rather than through the skill surface.
    test "a core skill is refused a sensitive setting through config_get too" do
      AlexClaw.Config.set("test.core_private", "s3cret",
        type: "string",
        category: "test",
        sensitive: true
      )

      assert {:error, :sensitive} =
               SafeExecutor.as_skill(AlexClaw.Skills.RSSCollector, fn ->
                 SkillAPI.config_get(AlexClaw.Skills.RSSCollector, "test.core_private")
               end)

      # ...and still reaches it directly.
      assert AlexClaw.Config.get("test.core_private") == "s3cret"
    end

    test "unknown module is denied" do
      assert {:error, :permission_denied} =
               SafeExecutor.as_skill(FakeModule, fn -> SkillAPI.config_get(FakeModule, "key") end)
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
