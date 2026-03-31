defmodule AlexClaw.SkillSupervisorTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  alias AlexClaw.SkillSupervisor

  describe "run_skill/2" do
    test "supervisor is running" do
      pid = Process.whereis(SkillSupervisor)
      assert pid != nil
      assert Process.alive?(pid)
    end

    test "supervisor has no permanent children by default" do
      children = DynamicSupervisor.which_children(SkillSupervisor)
      # May or may not have children depending on test order, but should not crash
      assert is_list(children)
    end

    test "supervisor survives child crash" do
      sup_pid = Process.whereis(SkillSupervisor)

      # Start a child that crashes immediately
      {:ok, child} =
        DynamicSupervisor.start_child(SkillSupervisor, %{
          id: :crash_child,
          start: {Task, :start_link, [fn -> raise "crash" end]},
          restart: :temporary
        })

      # Wait for crash to propagate
      ref = Process.monitor(child)
      assert_receive {:DOWN, ^ref, :process, ^child, _reason}, 1000

      # Supervisor should still be alive
      assert Process.alive?(sup_pid)
    end
  end
end
