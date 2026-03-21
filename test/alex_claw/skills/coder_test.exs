defmodule AlexClaw.Skills.CoderTest do
  use AlexClaw.DataCase

  alias AlexClaw.Skills.{Coder, SkillAPI}
  alias AlexClaw.Workflows.SkillRegistry

  describe "run/1" do
    test "returns {:error, :no_goal} when input is empty" do
      assert {:error, :no_goal} = Coder.run(%{input: ""})
      assert {:error, :no_goal} = Coder.run(%{input: nil})
      assert {:error, :no_goal} = Coder.run(%{})
    end
  end

  describe "new permission gating" do
    setup do
      skills_dir = Application.get_env(:alex_claw, :skills_dir)
      File.mkdir_p!(skills_dir)

      source = """
      defmodule AlexClaw.Skills.Dynamic.NoWriteSkill do
        @behaviour AlexClaw.Skill
        @impl true
        def permissions, do: [:config_read]
        @impl true
        def run(_args), do: {:ok, "no_write"}
      end
      """

      File.write!(Path.join(skills_dir, "no_write_skill.ex"), source)
      {:ok, _} = SkillRegistry.load_skill("no_write_skill.ex")

      on_exit(fn ->
        SkillRegistry.unload_skill("no_write_skill")
        File.rm_rf!(skills_dir)
      end)

      %{module: AlexClaw.Skills.Dynamic.NoWriteSkill}
    end

    test "skill without :skill_write cannot write_skill", %{module: mod} do
      assert {:error, :permission_denied} = SkillAPI.write_skill(mod, "test.ex", "code")
    end

    test "skill without :skill_write cannot read_skill", %{module: mod} do
      assert {:error, :permission_denied} = SkillAPI.read_skill(mod, "test.ex")
    end

    test "skill without :skill_manage cannot load_skill", %{module: mod} do
      assert {:error, :permission_denied} = SkillAPI.load_skill(mod, "test.ex")
    end

    test "skill without :skill_manage cannot unload_skill", %{module: mod} do
      assert {:error, :permission_denied} = SkillAPI.unload_skill(mod, "some_skill")
    end

    test "skill without :skill_manage cannot reload_skill", %{module: mod} do
      assert {:error, :permission_denied} = SkillAPI.reload_skill(mod, "some_skill")
    end

    test "skill without :workflow_manage cannot create_workflow", %{module: mod} do
      assert {:error, :permission_denied} = SkillAPI.create_workflow(mod, %{name: "test"})
    end

    test "skill without :workflow_manage cannot add_workflow_step", %{module: mod} do
      assert {:error, :permission_denied} = SkillAPI.add_workflow_step(mod, 1, %{name: "s"})
    end

    test "skill without :workflow_manage cannot run_workflow", %{module: mod} do
      assert {:error, :permission_denied} = SkillAPI.run_workflow(mod, 1)
    end

    test "skill without :workflow_manage cannot get_workflow_result", %{module: mod} do
      assert {:error, :permission_denied} = SkillAPI.get_workflow_result(mod, 1)
    end
  end

  describe "core skills pass new permissions" do
    test "core module can call write_skill (returns file error, not permission error)" do
      result = SkillAPI.write_skill(AlexClaw.Skills.RSSCollector, "test_core.ex", "code")
      # Should succeed (write to skills dir) or fail with file error, not permission
      assert result != {:error, :permission_denied}
    end

    test "core module can call load_skill (returns file error, not permission error)" do
      result = SkillAPI.load_skill(AlexClaw.Skills.RSSCollector, "nonexistent.ex")
      assert result != {:error, :permission_denied}
    end
  end

  describe "path traversal prevention" do
    test "write_skill rejects path traversal" do
      assert {:error, :invalid_filename} = SkillAPI.write_skill(AlexClaw.Skills.RSSCollector, "../etc/passwd", "code")
    end

    test "write_skill rejects forward slash" do
      assert {:error, :invalid_filename} = SkillAPI.write_skill(AlexClaw.Skills.RSSCollector, "sub/file.ex", "code")
    end

    test "write_skill rejects backslash" do
      assert {:error, :invalid_filename} = SkillAPI.write_skill(AlexClaw.Skills.RSSCollector, "sub\\file.ex", "code")
    end

    test "write_skill rejects non-.ex files" do
      assert {:error, :invalid_filename} = SkillAPI.write_skill(AlexClaw.Skills.RSSCollector, "script.sh", "code")
    end

    test "read_skill rejects path traversal" do
      assert {:error, :invalid_filename} = SkillAPI.read_skill(AlexClaw.Skills.RSSCollector, "../../etc/passwd")
    end
  end

  describe "write + load integration" do
    setup do
      skills_dir = Application.get_env(:alex_claw, :skills_dir)
      File.mkdir_p!(skills_dir)

      on_exit(fn ->
        SkillRegistry.unload_skill("integration_test")
        File.rm(Path.join(skills_dir, "integration_test.ex"))
      end)

      :ok
    end

    test "write valid code, load it, verify in registry" do
      code = """
      defmodule AlexClaw.Skills.Dynamic.IntegrationTest do
        @behaviour AlexClaw.Skill
        @impl true
        def permissions, do: [:config_read]
        @impl true
        def description, do: "integration test skill"
        @impl true
        def run(_args), do: {:ok, "integration works", :on_success}
      end
      """

      assert :ok = SkillAPI.write_skill(AlexClaw.Skills.RSSCollector, "integration_test.ex", code)
      assert {:ok, info} = SkillAPI.load_skill(AlexClaw.Skills.RSSCollector, "integration_test.ex")
      assert info.name == "integration_test"
      assert {:ok, AlexClaw.Skills.Dynamic.IntegrationTest} = SkillRegistry.resolve("integration_test")
    end
  end

  describe "known_permissions includes new ones" do
    test "includes :skill_write" do
      assert :skill_write in SkillAPI.known_permissions()
    end

    test "includes :skill_manage" do
      assert :skill_manage in SkillAPI.known_permissions()
    end

    test "includes :workflow_manage" do
      assert :workflow_manage in SkillAPI.known_permissions()
    end
  end

  describe "coder registered as core" do
    test "SkillRegistry resolves coder" do
      assert {:ok, AlexClaw.Skills.Coder} = SkillRegistry.resolve("coder")
    end
  end

  describe "full generation loop" do
    @describetag :integration

    test "generates and loads a skill from natural language" do
      result = Coder.run(%{input: "a skill that returns the current Erlang system time as a string"})

      case result do
        {:ok, _text, branch} ->
          assert branch in [:on_created, :on_workflow_created]

        {:error, {:llm_failed, _}} ->
          # LM Studio not running — expected in CI
          :ok

        {:error, {:generation_failed, _}} ->
          # LLM couldn't produce valid code in retries
          :ok
      end
    end
  end
end
