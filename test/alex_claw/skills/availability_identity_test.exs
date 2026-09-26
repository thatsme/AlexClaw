defmodule AlexClaw.Skills.AvailabilityIdentityTest do
  @moduledoc """
  A skill's availability callbacks run as that skill, never as the skill that
  asked for it (S9 fix review, C1 remainder).

  `SafeExecutor.run/5` asks the target whether it is available before it
  starts it, in the caller's process. Before this, the target's
  `available?/1` ran there under the caller's identity: a skill run by another
  (`run_skill/3`) could make SkillAPI calls with the caller's rights by naming
  it. Now `available?` and `unavailable_reason/0` run as the target, with no
  secrets.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.SafeExecutor
  alias AlexClaw.Workflows.{SkillRegistry, StepConfig}

  defp write_skill(name, permissions, body) do
    module = "AlexClaw.Skills.Dynamic.#{Macro.camelize(name)}"

    File.write!(Path.join(Application.get_env(:alex_claw, :skills_dir), "#{name}.ex"), """
    defmodule #{module} do
      @behaviour AlexClaw.Skill
      @impl true
      def version, do: "1.0.0"
      @impl true
      def description, do: "availability identity probe"
      @impl true
      def permissions, do: #{inspect(permissions)}
      #{body}
      @impl true
      def run(_args), do: {:ok, "ran", :on_success}
    end
    """)

    {:ok, %{module: loaded}} = SkillRegistry.load_skill("#{name}.ex")
    loaded
  end

  setup do
    dir = Application.get_env(:alex_claw, :skills_dir)
    File.mkdir_p!(dir)

    on_exit(fn ->
      for name <- ~w(avail_caller avail_target), do: SkillRegistry.unload_skill(name)
      File.rm_rf!(dir)
    end)

    caller = write_skill("avail_caller", [:memory_read], "")

    # Available only if a SkillAPI call naming the caller succeeds from inside
    # the callback: the caller has memory_read, the target has nothing.
    target =
      write_skill("avail_target", [], """
      @impl true
      def available?(_config) do
        match?({:ok, _}, AlexClaw.Skills.SkillAPI.memory_recent(#{inspect(caller)}))
      end
      """)

    %{caller: caller, target: target}
  end

  test "a target's available? run from another skill does not get the caller's rights", ctx do
    assert {:error, {:unavailable, _reason}} =
             SafeExecutor.as_skill(ctx.caller, fn ->
               SafeExecutor.run(ctx.target, %{config: %{}}, :dynamic, nil, [])
             end)
  end

  test "availability asked by any code is answered as the target", ctx do
    refute SafeExecutor.as_skill(ctx.caller, fn -> StepConfig.available?(ctx.target, %{}) end)
  end

  test "the callback runs as the target, and the caller's identity is back afterwards", ctx do
    SafeExecutor.as_skill(ctx.caller, fn ->
      StepConfig.available?(ctx.target, %{})
      assert SafeExecutor.running_skill() == ctx.caller
    end)
  end
end
