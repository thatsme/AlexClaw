defmodule AlexClaw.Skills.SkillIdentityTest do
  @moduledoc """
  A SkillAPI call is checked against the skill that is running, never against
  the module the call names (S8 C1; THREAT_MODEL P9, P3, P6).

  Every SkillAPI function takes the skill's module as its first argument.
  Before S9 that argument was the identity: a skill that named a core skill
  (`SkillAPI.memory_recent(AlexClaw.Skills.RSSCollector)`) got the core fast
  path, `:all`, and every check was skipped. Now the identity is the one
  `AlexClaw.Auth.SafeExecutor` recorded when it started the skill — a skill
  cannot write it (no `Process.put` passes containment) — and a call that
  names another module is refused. Code that is not a running skill has no
  identity and is refused, whatever it names; core code acting as a skill says
  so through `SafeExecutor.as_skill/2`, which no contained skill can call.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.SafeExecutor
  alias AlexClaw.Skills.SkillAPI
  alias AlexClaw.Workflows.SkillRegistry

  @core AlexClaw.Skills.RSSCollector

  defp write_skill(name, permissions, extra \\ "") do
    module = "AlexClaw.Skills.Dynamic.#{Macro.camelize(name)}"

    File.write!(Path.join(Application.get_env(:alex_claw, :skills_dir), "#{name}.ex"), """
    defmodule #{module} do
      @behaviour AlexClaw.Skill
      @impl true
      def version, do: "1.0.0"
      @impl true
      def description, do: "identity probe"
      @impl true
      def permissions, do: #{inspect(permissions)}
      #{extra}
      @impl true
      def run(%{call: "borrow"}), do: {:ok, AlexClaw.Skills.SkillAPI.memory_recent(#{inspect(@core)})}
      def run(%{call: "own"}), do: {:ok, AlexClaw.Skills.SkillAPI.memory_recent(__MODULE__)}
    end
    """)

    {:ok, %{module: loaded}} = SkillRegistry.load_skill("#{name}.ex")
    loaded
  end

  setup do
    dir = Application.get_env(:alex_claw, :skills_dir)
    File.mkdir_p!(dir)

    on_exit(fn ->
      for name <- ~w(identity_none identity_reader identity_loader),
          do: SkillRegistry.unload_skill(name)

      File.rm_rf!(dir)
    end)

    :ok
  end

  defp run(module, call), do: SafeExecutor.run(module, %{call: call}, :dynamic, nil, [])

  test "a skill that names a core skill is refused" do
    skill = write_skill("identity_none", [])

    assert {:ok, {:error, :permission_denied}} = run(skill, "borrow")
  end

  test "a skill with the permission, naming a core skill, is refused too: the name is a lie" do
    skill = write_skill("identity_reader", [:memory_read])

    assert {:ok, {:error, :permission_denied}} = run(skill, "borrow")
  end

  test "a skill without the permission is refused under its own name" do
    skill = write_skill("identity_none", [])

    assert {:ok, {:error, :permission_denied}} = run(skill, "own")
  end

  test "a skill with the permission is allowed under its own name" do
    skill = write_skill("identity_reader", [:memory_read])

    assert {:ok, {:ok, _entries}} = run(skill, "own")
  end

  test "code that is not a running skill is refused, whatever it names" do
    assert {:error, :permission_denied} = SkillAPI.memory_recent(@core)
  end

  test "core code acting as a core skill keeps its rights" do
    assert {:ok, _entries} = SafeExecutor.as_skill(@core, fn -> SkillAPI.memory_recent(@core) end)
  end

  # The registry calls routes/0 while loading, in its own process and before
  # any SafeExecutor: the callback must not borrow a core skill's rights there.
  test "a load-time callback cannot use a core skill's rights" do
    write_skill("identity_loader", [], """
    @impl true
    def routes do
      case AlexClaw.Skills.SkillAPI.memory_recent(#{inspect(@core)}) do
        {:ok, _} -> [:on_success, :borrowed]
        _refused -> [:on_success]
      end
    end
    """)

    assert SkillRegistry.get_routes("identity_loader") == [:on_success]
  end
end
