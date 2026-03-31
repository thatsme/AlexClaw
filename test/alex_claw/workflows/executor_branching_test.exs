defmodule AlexClaw.Workflows.ExecutorBranchingTest do
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Workflows
  alias AlexClaw.Workflows.Executor

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(AlexClaw.Repo, {:shared, self()})
    :ok
  end

  defp create_workflow(attrs \\ %{}) do
    default = %{name: "Branch WF #{System.unique_integer([:positive])}", enabled: true}
    {:ok, wf} = Workflows.create_workflow(Map.merge(default, attrs))
    wf
  end

  describe "linear backward compatibility" do
    test "workflow with no routes executes linearly" do
      bypass = Bypass.open()

      Bypass.expect(bypass, fn conn ->
        Plug.Conn.resp(conn, 200, "output")
      end)

      wf = create_workflow()

      {:ok, _} = Workflows.add_step(wf, %{name: "S1", skill: "api_request",
        config: %{"url" => "http://localhost:#{bypass.port}/s1"}})
      {:ok, _} = Workflows.add_step(wf, %{name: "S2", skill: "api_request",
        config: %{"url" => "http://localhost:#{bypass.port}/s2"}})

      {:ok, run} = Executor.run(wf.id)
      assert run.status == "completed"
      assert run.step_results["1"]["name"] == "S1"
      assert run.step_results["2"]["name"] == "S2"
    end

    test "step results include branch info" do
      bypass = Bypass.open()

      Bypass.expect(bypass, fn conn ->
        Plug.Conn.resp(conn, 200, "ok")
      end)

      wf = create_workflow()
      {:ok, _} = Workflows.add_step(wf, %{name: "Fetch", skill: "api_request",
        config: %{"url" => "http://localhost:#{bypass.port}/data"}})

      {:ok, run} = Executor.run(wf.id)
      assert run.step_results["1"]["branch"] == "on_2xx"
    end
  end

  describe "conditional branching" do
    test "routes step to specified target on matching branch" do
      bypass = Bypass.open()

      Bypass.expect(bypass, fn conn ->
        Plug.Conn.resp(conn, 200, "data")
      end)

      wf = create_workflow()

      # Step 1: API call → on_2xx routes to step 3 (skips step 2)
      {:ok, _} = Workflows.add_step(wf, %{name: "Fetch", skill: "api_request",
        config: %{"url" => "http://localhost:#{bypass.port}/data"},
        routes: [%{"branch" => "on_2xx", "goto" => 3}, %{"branch" => "on_error", "goto" => 2}]})

      # Step 2: error handler (should be skipped on success)
      {:ok, _} = Workflows.add_step(wf, %{name: "Error Handler", skill: "api_request",
        config: %{"url" => "http://localhost:#{bypass.port}/error"}})

      # Step 3: success handler
      {:ok, _} = Workflows.add_step(wf, %{name: "Success", skill: "api_request",
        config: %{"url" => "http://localhost:#{bypass.port}/success"}})

      {:ok, run} = Executor.run(wf.id)
      assert run.status == "completed"
      # Step 1 and 3 executed, step 2 skipped
      assert Map.has_key?(run.step_results, "1")
      refute Map.has_key?(run.step_results, "2")
      assert Map.has_key?(run.step_results, "3")
    end

    test "on_error route prevents workflow halt" do
      bypass = Bypass.open()

      Bypass.expect(bypass, fn conn ->
        Plug.Conn.resp(conn, 200, "recovered")
      end)

      wf = create_workflow()

      # Step 1: unknown skill → errors out
      # Route on_error → step 2 (recovery)
      {:ok, _} = Workflows.add_step(wf, %{name: "Will Fail", skill: "nonexistent_skill",
        routes: [%{"branch" => "on_error", "goto" => 2}]})

      # Step 2: recovery step
      {:ok, _} = Workflows.add_step(wf, %{name: "Recover", skill: "api_request",
        config: %{"url" => "http://localhost:#{bypass.port}/recover"}})

      {:ok, run} = Executor.run(wf.id)
      assert run.status == "completed"
      assert run.step_results["1"]["error"] =~ "unknown_skill"
      assert run.step_results["2"]["name"] == "Recover"
    end

    test "no matching route terminates workflow" do
      bypass = Bypass.open()

      Bypass.expect(bypass, fn conn ->
        Plug.Conn.resp(conn, 200, "done")
      end)

      wf = create_workflow()

      # Step 1 has routes but on_2xx is not listed — no match → workflow ends
      {:ok, _} = Workflows.add_step(wf, %{name: "Terminal", skill: "api_request",
        config: %{"url" => "http://localhost:#{bypass.port}/data"},
        routes: [%{"branch" => "on_4xx", "goto" => 2}]})

      # Step 2 should never be reached
      {:ok, _} = Workflows.add_step(wf, %{name: "Unreached", skill: "api_request",
        config: %{"url" => "http://localhost:#{bypass.port}/nope"}})

      {:ok, run} = Executor.run(wf.id)
      assert run.status == "completed"
      assert Map.has_key?(run.step_results, "1")
      refute Map.has_key?(run.step_results, "2")
    end

    test "end route target terminates workflow" do
      bypass = Bypass.open()

      Bypass.expect(bypass, fn conn ->
        Plug.Conn.resp(conn, 200, "done")
      end)

      wf = create_workflow()

      {:ok, _} = Workflows.add_step(wf, %{name: "S1", skill: "api_request",
        config: %{"url" => "http://localhost:#{bypass.port}/s1"},
        routes: [%{"branch" => "on_2xx", "goto" => "end"}]})

      {:ok, _} = Workflows.add_step(wf, %{name: "S2", skill: "api_request",
        config: %{"url" => "http://localhost:#{bypass.port}/s2"}})

      {:ok, run} = Executor.run(wf.id)
      assert run.status == "completed"
      assert Map.has_key?(run.step_results, "1")
      refute Map.has_key?(run.step_results, "2")
    end

    test "default route is used when no branch matches" do
      bypass = Bypass.open()

      Bypass.expect(bypass, fn conn ->
        Plug.Conn.resp(conn, 200, "ok")
      end)

      wf = create_workflow()

      # Step 1: routes on_4xx to step 3, default to step 2
      {:ok, _} = Workflows.add_step(wf, %{name: "S1", skill: "api_request",
        config: %{"url" => "http://localhost:#{bypass.port}/s1"},
        routes: [%{"branch" => "on_4xx", "goto" => 3}, %{"branch" => "default", "goto" => 2}]})

      {:ok, _} = Workflows.add_step(wf, %{name: "Default Path", skill: "api_request",
        config: %{"url" => "http://localhost:#{bypass.port}/s2"},
        routes: [%{"branch" => "on_2xx", "goto" => "end"}]})

      {:ok, _} = Workflows.add_step(wf, %{name: "Error Path", skill: "api_request",
        config: %{"url" => "http://localhost:#{bypass.port}/s3"}})

      {:ok, run} = Executor.run(wf.id)
      assert run.status == "completed"
      assert Map.has_key?(run.step_results, "1")
      assert Map.has_key?(run.step_results, "2")
      refute Map.has_key?(run.step_results, "3")
    end
  end

  describe "loop protection" do
    test "detects and halts infinite loops" do
      bypass = Bypass.open()

      Bypass.expect(bypass, fn conn ->
        Plug.Conn.resp(conn, 200, "looping")
      end)

      wf = create_workflow()

      # Step 1 routes back to step 1 — infinite loop
      {:ok, _} = Workflows.add_step(wf, %{name: "Loop", skill: "api_request",
        config: %{"url" => "http://localhost:#{bypass.port}/loop"},
        routes: [%{"branch" => "on_2xx", "goto" => 1}]})

      {:error, run} = Executor.run(wf.id)
      assert run.status == "failed"
      assert run.error =~ "loop_detected"
    end
  end

  describe "mixed workflows" do
    test "some steps with routes, some without" do
      bypass = Bypass.open()

      Bypass.expect(bypass, fn conn ->
        Plug.Conn.resp(conn, 200, "data")
      end)

      wf = create_workflow()

      # Step 1: no routes → falls through to step 2
      {:ok, _} = Workflows.add_step(wf, %{name: "Linear", skill: "api_request",
        config: %{"url" => "http://localhost:#{bypass.port}/s1"}})

      # Step 2: routes on_2xx to step 3
      {:ok, _} = Workflows.add_step(wf, %{name: "Branching", skill: "api_request",
        config: %{"url" => "http://localhost:#{bypass.port}/s2"},
        routes: [%{"branch" => "on_2xx", "goto" => 3}]})

      # Step 3: no routes → workflow complete
      {:ok, _} = Workflows.add_step(wf, %{name: "Final", skill: "api_request",
        config: %{"url" => "http://localhost:#{bypass.port}/s3"}})

      {:ok, run} = Executor.run(wf.id)
      assert run.status == "completed"
      assert map_size(run.step_results) == 3
    end
  end

  describe "circuit breaker skip bypasses routes" do
    test "skipped step falls through to next position, ignoring routes" do
      bypass = Bypass.open()

      Bypass.expect(bypass, fn conn ->
        Plug.Conn.resp(conn, 200, "ok")
      end)

      wf = create_workflow()

      # Step 1: missing skill with on_missing_skill: skip
      # Has routes that would send to step 3, but skip should go to step 2
      {:ok, _} = Workflows.add_step(wf, %{name: "Missing", skill: "gone_skill",
        config: %{"on_missing_skill" => "skip"},
        routes: [%{"branch" => "on_success", "goto" => 3}]})

      # Step 2: should be reached (skip falls through to next position)
      {:ok, _} = Workflows.add_step(wf, %{name: "Next", skill: "api_request",
        config: %{"url" => "http://localhost:#{bypass.port}/next"},
        routes: [%{"branch" => "on_2xx", "goto" => "end"}]})

      # Step 3: should NOT be reached (step 1 skipped → step 2 → end)
      {:ok, _} = Workflows.add_step(wf, %{name: "Routed", skill: "api_request",
        config: %{"url" => "http://localhost:#{bypass.port}/routed"}})

      {:ok, run} = Executor.run(wf.id)
      assert run.status == "completed"
      assert run.step_results["1"]["branch"] == "skipped"
      assert Map.has_key?(run.step_results, "2")
      refute Map.has_key?(run.step_results, "3")
    end
  end
end
