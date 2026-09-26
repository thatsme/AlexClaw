defmodule AlexClaw.Skills.CoderTest do
  use AlexClaw.DataCase
  @moduletag :integration

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

    test "skill without :workflow_manage cannot get_workflow_result", %{module: mod} do
      assert {:error, :permission_denied} = SkillAPI.get_workflow_result(mod, 1)
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
      result =
        Coder.run(%{input: "a skill that returns the current Erlang system time as a string"})

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
