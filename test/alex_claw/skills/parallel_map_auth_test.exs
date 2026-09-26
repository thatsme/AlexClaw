defmodule AlexClaw.Skills.ParallelMapAuthTest do
  @moduledoc """
  `SkillAPI.parallel_map/4` runs each element with the calling skill's
  authorisation (0.4.0 S6, accepted; pinned in S7).

  A SkillAPI call is checked against the skill's declared permissions, looked
  up by module, and against what the calling process carries: an attenuated
  capability token and the invocation chain depth. A task started without
  those would be checked as an unattenuated, top-level call — more than the
  caller may do. Each case below is refused in the caller and must be refused
  the same way inside `parallel_map/4`.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.{CapabilityToken, SafeExecutor}
  alias AlexClaw.Skills.SkillAPI
  alias AlexClaw.Workflows.SkillRegistry

  @module AlexClaw.Skills.Dynamic.ParallelProbe

  setup do
    dir = Application.get_env(:alex_claw, :skills_dir)
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "parallel_probe.ex"), """
    defmodule AlexClaw.Skills.Dynamic.ParallelProbe do
      @behaviour AlexClaw.Skill
      @impl true
      def permissions, do: [:config_read]
      @impl true
      def run(_args), do: {:ok, "probe", :on_success}
    end
    """)

    {:ok, _} = SkillRegistry.load_skill("parallel_probe.ex")
    AlexClaw.Config.set("probe.key", "value", type: "string", category: "test")

    on_exit(fn ->
      SkillRegistry.unload_skill("parallel_probe")
      File.rm_rf!(dir)
    end)

    :ok
  end

  # SkillAPI checks the running skill (S9): the probe runs as itself, as
  # SafeExecutor would start it, and its tasks must inherit that identity too.
  defp as_probe(fun), do: SafeExecutor.as_skill(@module, fun)

  defp read_in_parallel,
    do:
      SkillAPI.parallel_map(
        @module,
        [1, 2],
        fn _ -> SkillAPI.config_get(@module, "probe.key") end,
        max_concurrency: 2
      )

  test "a declared permission is granted inside parallel_map, as outside" do
    assert {:ok, "value"} = as_probe(fn -> SkillAPI.config_get(@module, "probe.key") end)
    assert {:ok, [{:ok, "value"}, {:ok, "value"}]} = as_probe(&read_in_parallel/0)
  end

  test "a permission the skill does not declare is refused inside parallel_map" do
    assert {:ok, [{:error, :permission_denied}, {:error, :permission_denied}]} =
             as_probe(fn ->
               SkillAPI.parallel_map(@module, [1, 2], fn _ -> SkillAPI.memory_recent(@module) end)
             end)
  end

  # The token was attenuated to :llm by whoever invoked this skill: the
  # declared :config_read is not available to this call chain.
  test "a caller's attenuated token still binds inside parallel_map" do
    Process.put(:auth_token, CapabilityToken.mint([:llm]))

    assert {:error, :permission_denied} =
             as_probe(fn -> SkillAPI.config_get(@module, "probe.key") end)

    assert {:ok, [{:error, :permission_denied}, {:error, :permission_denied}]} =
             as_probe(&read_in_parallel/0)
  end

  test "a caller's chain depth still binds inside parallel_map" do
    Process.put(:auth_chain_depth, 1_000)

    assert {:error, :permission_denied} =
             as_probe(fn -> SkillAPI.config_get(@module, "probe.key") end)

    assert {:ok, [{:error, :permission_denied}, {:error, :permission_denied}]} =
             as_probe(&read_in_parallel/0)
  end
end
