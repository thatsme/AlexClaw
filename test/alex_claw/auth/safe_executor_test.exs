defmodule AlexClaw.Auth.SafeExecutorTest do
  use ExUnit.Case, async: true
  @moduletag :unit
  @moduletag :adversarial

  alias AlexClaw.Auth.{CapabilityToken, SafeExecutor}

  # --- Test skill modules defined inline ---

  defmodule SuccessSkill do
    def run(_args), do: {:ok, "done", :on_success}
  end

  defmodule CrashSkill do
    def run(_args), do: raise("boom")
  end

  defmodule SlowSkill do
    def run(_args) do
      Process.sleep(:infinity)
      {:ok, "never", :on_success}
    end
  end

  defmodule ErrorSkill do
    def run(_args), do: {:error, :something_broke}
  end

  describe "core skill execution" do
    test "returns result directly for core skills" do
      assert {:ok, "done", :on_success} = SafeExecutor.run(SuccessSkill, %{}, :core, nil, [])
    end

    test "propagates exceptions from core skills" do
      assert_raise RuntimeError, "boom", fn ->
        SafeExecutor.run(CrashSkill, %{}, :core, nil, [])
      end
    end

    test "returns error tuples from core skills" do
      assert {:error, :something_broke} = SafeExecutor.run(ErrorSkill, %{}, :core, nil, [])
    end

    test "ignores token for core skills" do
      token = CapabilityToken.mint([:run_skill])
      assert {:ok, "done", :on_success} = SafeExecutor.run(SuccessSkill, %{}, :core, token, [])
    end
  end

  describe "dynamic skill execution" do
    test "returns result for dynamic skills with token" do
      token = CapabilityToken.mint([:run_skill])
      assert {:ok, "done", :on_success} = SafeExecutor.run(SuccessSkill, %{}, :dynamic, token, [])
    end

    test "returns result for dynamic skills with nil token" do
      assert {:ok, "done", :on_success} = SafeExecutor.run(SuccessSkill, %{}, :dynamic, nil, [])
    end

    test "times out on slow dynamic skills" do
      token = CapabilityToken.mint([:run_skill])

      assert {:error, :skill_timeout} =
               SafeExecutor.run(SlowSkill, %{}, :dynamic, token, timeout: 50)
    end

    test "crash in dynamic skill child process propagates as EXIT" do
      token = CapabilityToken.mint([:run_skill])

      # Task.async links to the caller — a crash in the child sends an EXIT
      # signal to the test process. We trap exits to observe it.
      Process.flag(:trap_exit, true)

      pid = spawn_link(fn ->
        SafeExecutor.run(CrashSkill, %{}, :dynamic, token, [])
      end)

      assert_receive {:EXIT, ^pid, _reason}, 5_000
    end

    test "returns error tuples from dynamic skills" do
      token = CapabilityToken.mint([:run_skill])
      assert {:error, :something_broke} = SafeExecutor.run(ErrorSkill, %{}, :dynamic, token, [])
    end
  end

  describe "invalid module" do
    test "raises when module does not exist for core" do
      assert_raise UndefinedFunctionError, fn ->
        SafeExecutor.run(NonExistentModule, %{}, :core, nil, [])
      end
    end

    test "nonexistent module in dynamic skill propagates as EXIT" do
      token = CapabilityToken.mint([:run_skill])

      Process.flag(:trap_exit, true)

      pid = spawn_link(fn ->
        SafeExecutor.run(NonExistentModule, %{}, :dynamic, token, [])
      end)

      assert_receive {:EXIT, ^pid, _reason}, 5_000
    end
  end
end
