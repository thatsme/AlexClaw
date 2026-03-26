defmodule AlexClaw.Workflows.RegistryTest do
  use AlexClaw.DataCase, async: false

  alias AlexClaw.Workflows.Registry

  describe "register/4 and lookup/1" do
    test "registers a run and finds it via lookup" do
      pid = self()
      :ok = Registry.register(999_999, pid, 1, "Test Workflow")

      assert {:ok, run} = Registry.lookup(999_999)
      assert run.run_id == 999_999
      assert run.workflow_id == 1
      assert run.workflow_name == "Test Workflow"
      assert run.current_step == nil

      Registry.deregister(999_999)
      Process.sleep(50)
    end

    test "lookup returns error for unknown run" do
      assert {:error, :not_found} = Registry.lookup(0)
    end
  end

  describe "list_active/0" do
    test "lists all registered runs" do
      pid = self()
      :ok = Registry.register(888_001, pid, 1, "WF One")
      :ok = Registry.register(888_002, pid, 2, "WF Two")

      active = Registry.list_active()
      ids = Enum.map(active, & &1.run_id) |> Enum.sort()
      assert 888_001 in ids
      assert 888_002 in ids

      Registry.deregister(888_001)
      Registry.deregister(888_002)
      Process.sleep(50)
    end

    test "returns empty when nothing is running" do
      active = Registry.list_active() |> Enum.filter(&(&1.run_id >= 777_000))
      assert active == []
    end
  end

  describe "update_step/2" do
    test "updates the current step for a run" do
      pid = self()
      :ok = Registry.register(777_001, pid, 1, "Step Test")

      Registry.update_step(777_001, "Fetch RSS")
      assert {:ok, run} = Registry.lookup(777_001)
      assert run.current_step == "Fetch RSS"

      Registry.update_step(777_001, "Notify")
      assert {:ok, run} = Registry.lookup(777_001)
      assert run.current_step == "Notify"

      Registry.deregister(777_001)
      Process.sleep(50)
    end
  end

  describe "deregister/1" do
    test "removes a run from the registry" do
      pid = self()
      :ok = Registry.register(666_001, pid, 1, "Deregister Test")
      Registry.deregister(666_001)
      Process.sleep(50)

      assert {:error, :not_found} = Registry.lookup(666_001)
    end
  end

  describe "process crash cleanup" do
    test "auto-deregisters on process exit" do
      parent = self()

      pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      :ok = Registry.register(555_001, pid, 1, "Crash Test")
      assert {:ok, _} = Registry.lookup(555_001)

      Process.exit(pid, :kill)
      Process.sleep(100)

      assert {:error, :not_found} = Registry.lookup(555_001)
    end
  end

  describe "cancel/1" do
    test "returns error for unknown run" do
      assert {:error, :not_found} = Registry.cancel(0)
    end
  end
end
