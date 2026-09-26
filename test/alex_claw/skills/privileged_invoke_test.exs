defmodule AlexClaw.Skills.PrivilegedInvokeTest do
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.SafeExecutor
  alias AlexClaw.Skills.SkillAPI
  alias AlexClaw.Workflows.SkillRegistry

  setup do
    skills_dir = Application.get_env(:alex_claw, :skills_dir)
    File.mkdir_p!(skills_dir)

    File.write!(Path.join(skills_dir, "invoker.ex"), """
    defmodule AlexClaw.Skills.Dynamic.Invoker do
      @behaviour AlexClaw.Skill
      @impl true
      def permissions, do: [:skill_invoke]
      @impl true
      def description, do: "invokes other skills"
      @impl true
      def run(_args), do: {:ok, "ok", :on_success}
    end
    """)

    {:ok, _} = SkillRegistry.load_skill("invoker.ex")

    on_exit(fn ->
      SkillRegistry.unload_skill("invoker")
      File.rm_rf!(skills_dir)
    end)

    %{skill: AlexClaw.Skills.Dynamic.Invoker}
  end

  # run_skill resolves core skills and calls run/1 directly. The Dispatcher's 2FA
  # gate is not on this path, so these four were reachable from any skill holding
  # :skill_invoke.
  describe "privileged skills are unreachable by cross-skill invocation" do
    test "each denied target is refused", %{skill: skill} do
      for target <- ~w(shell coder db_backup web_automation) do
        assert {:error, :privileged_skill} =
                 SafeExecutor.as_skill(skill, fn ->
                   SkillAPI.run_skill(skill, target, %{input: "x"})
                 end),
               "#{target} was reachable through run_skill"
      end
    end

    test "shell is refused even when shell.enabled is true", %{skill: skill} do
      AlexClaw.Config.set("shell.enabled", "true", type: "boolean", category: "shell")

      assert {:error, :privileged_skill} =
               SafeExecutor.as_skill(skill, fn ->
                 SkillAPI.run_skill(skill, "shell", %{input: "df -h"})
               end)
    end

    test "the refusal happens before the skill is resolved", %{skill: skill} do
      # A denied name that is not registered still reports the denial, not :unknown_skill.
      assert {:error, :privileged_skill} =
               SafeExecutor.as_skill(skill, fn -> SkillAPI.run_skill(skill, "db_backup", %{}) end)
    end

    test "an ordinary skill is still invocable", %{skill: skill} do
      # web_fetch is not on the deny list; it resolves and runs.
      refute match?(
               {:error, :privileged_skill},
               SafeExecutor.as_skill(skill, fn -> SkillAPI.run_skill(skill, "web_fetch", %{}) end)
             )
    end

    test "an unknown skill still reports itself as unknown", %{skill: skill} do
      assert {:error, {:unknown_skill, "no_such_skill"}} =
               SafeExecutor.as_skill(skill, fn ->
                 SkillAPI.run_skill(skill, "no_such_skill", %{})
               end)
    end
  end

  describe "the permission check still comes first" do
    setup do
      skills_dir = Application.get_env(:alex_claw, :skills_dir)

      File.write!(Path.join(skills_dir, "bystander.ex"), """
      defmodule AlexClaw.Skills.Dynamic.Bystander do
        @behaviour AlexClaw.Skill
        @impl true
        def permissions, do: [:llm]
        @impl true
        def description, do: "no invoke permission"
        @impl true
        def run(_args), do: {:ok, "ok", :on_success}
      end
      """)

      {:ok, _} = SkillRegistry.load_skill("bystander.ex")
      on_exit(fn -> SkillRegistry.unload_skill("bystander") end)
      :ok
    end

    test "a skill without :skill_invoke is denied on permission, not on the list" do
      assert {:error, :permission_denied} =
               SafeExecutor.as_skill(AlexClaw.Skills.Dynamic.Bystander, fn ->
                 SkillAPI.run_skill(AlexClaw.Skills.Dynamic.Bystander, "shell", %{})
               end)
    end
  end
end
