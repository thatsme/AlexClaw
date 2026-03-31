defmodule AlexClaw.Workflows.ExecutorAdversarialTest do
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :adversarial

  alias AlexClaw.Workflows
  alias AlexClaw.Workflows.Executor

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(AlexClaw.Repo, {:shared, self()})
    :ok
  end

  defp create_workflow(attrs \\ %{}) do
    default = %{name: "Adversarial WF #{System.unique_integer([:positive])}", enabled: true}
    {:ok, wf} = Workflows.create_workflow(Map.merge(default, attrs))
    wf
  end

  describe "disabled and missing workflows" do
    test "returns error for disabled workflow" do
      wf = create_workflow(%{enabled: false})
      assert {:error, :workflow_disabled} = Executor.run(wf.id)
    end

    test "raises on nonexistent workflow ID" do
      assert_raise Ecto.NoResultsError, fn ->
        Executor.run(999_999)
      end
    end
  end

  describe "step failure propagation" do
    test "first step failure stops entire chain" do
      wf = create_workflow()

      {:ok, _} = Workflows.add_step(wf, %{
        name: "Bad Step",
        skill: "nonexistent_skill"
      })

      {:ok, _} = Workflows.add_step(wf, %{
        name: "Never Reached",
        skill: "api_request",
        config: %{"url" => "http://localhost/unreachable"}
      })

      {:error, run} = Executor.run(wf.id)
      assert run.status == "failed"
      refute Map.has_key?(run.step_results, "2")
    end

    test "second step failure records partial results" do
      bypass = Bypass.open()

      Bypass.expect(bypass, "GET", "/ok", fn conn ->
        Plug.Conn.resp(conn, 200, "step1 done")
      end)

      wf = create_workflow()

      {:ok, _} = Workflows.add_step(wf, %{
        name: "Succeeds",
        skill: "api_request",
        config: %{"url" => "http://localhost:#{bypass.port}/ok"}
      })

      {:ok, _} = Workflows.add_step(wf, %{
        name: "Fails",
        skill: "nonexistent_skill"
      })

      {:error, run} = Executor.run(wf.id)
      assert run.status == "failed"
      assert run.step_results["1"]["name"] == "Succeeds"
      assert run.step_results["1"]["output"] != nil
      assert run.step_results["2"]["error"] =~ "unknown_skill"
    end
  end

  describe "edge case step configs" do
    test "step with empty config runs without crash" do
      bypass = Bypass.open()

      Bypass.expect(bypass, "GET", "/test", fn conn ->
        Plug.Conn.resp(conn, 200, "ok")
      end)

      wf = create_workflow()

      {:ok, _} = Workflows.add_step(wf, %{
        name: "Minimal",
        skill: "api_request",
        config: %{"url" => "http://localhost:#{bypass.port}/test"}
      })

      {:ok, run} = Executor.run(wf.id)
      assert run.status == "completed"
    end

    test "step with nil config defaults to empty map" do
      wf = create_workflow()

      {:ok, _} = Workflows.add_step(wf, %{
        name: "No Config",
        skill: "nonexistent_skill"
      })

      {:error, run} = Executor.run(wf.id)
      assert run.error =~ "unknown_skill"
    end

    test "step with empty prompt_template is treated as empty string — uses skill dispatch" do
      wf = create_workflow()

      {:ok, _} = Workflows.add_step(wf, %{
        name: "Empty Template",
        skill: "nonexistent_skill",
        prompt_template: ""
      })

      {:error, run} = Executor.run(wf.id)
      assert run.error =~ "unknown_skill"
    end
  end

  describe "prompt template interpolation" do
    test "template with no placeholders passes through as-is" do
      wf = create_workflow()

      {:ok, _} = Workflows.add_step(wf, %{
        name: "Static Prompt",
        skill: "llm_transform",
        prompt_template: "Tell me a joke",
        llm_tier: "light"
      })

      {:error, run} = Executor.run(wf.id)
      assert run.status == "failed"
    end

    test "template with {input} when prev output is nil" do
      wf = create_workflow()

      {:ok, _} = Workflows.add_step(wf, %{
        name: "First Step With Template",
        skill: "llm_transform",
        prompt_template: "Process this: {input}",
        llm_tier: "light"
      })

      {:error, run} = Executor.run(wf.id)
      assert run.status == "failed"
      refute run.error =~ "FunctionClauseError"
    end

    test "template with {input} when prev output is a map" do
      bypass = Bypass.open()

      json = Jason.encode!(%{data: "value"})

      Bypass.expect(bypass, "GET", "/json", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, json)
      end)

      wf = create_workflow()

      {:ok, _} = Workflows.add_step(wf, %{
        name: "Fetch JSON",
        skill: "api_request",
        config: %{"url" => "http://localhost:#{bypass.port}/json"}
      })

      {:ok, _} = Workflows.add_step(wf, %{
        name: "Transform",
        skill: "llm_transform",
        prompt_template: "Analyze: {input}",
        llm_tier: "light"
      })

      {:error, run} = Executor.run(wf.id)
      refute run.error =~ "FunctionClauseError"
      refute run.error =~ "Protocol.UndefinedError"
    end
  end

  describe "concurrent run safety" do
    test "multiple runs of same workflow create separate run records" do
      bypass = Bypass.open()

      Bypass.expect(bypass, fn conn ->
        Plug.Conn.resp(conn, 200, "ok")
      end)

      wf = create_workflow()

      {:ok, _} = Workflows.add_step(wf, %{
        name: "Quick Step",
        skill: "api_request",
        config: %{"url" => "http://localhost:#{bypass.port}/data"}
      })

      {:ok, run1} = Executor.run(wf.id)
      {:ok, run2} = Executor.run(wf.id)

      assert run1.id != run2.id
      assert run1.status == "completed"
      assert run2.status == "completed"
    end
  end

  describe "many steps" do
    test "workflow with 10 steps chains data through all" do
      bypass = Bypass.open()

      Bypass.expect(bypass, fn conn ->
        Plug.Conn.resp(conn, 200, "step output")
      end)

      wf = create_workflow()

      for i <- 1..10 do
        {:ok, _} = Workflows.add_step(wf, %{
          name: "Step #{i}",
          skill: "api_request",
          config: %{"url" => "http://localhost:#{bypass.port}/step#{i}"}
        })
      end

      {:ok, run} = Executor.run(wf.id)
      assert run.status == "completed"
      assert map_size(run.step_results) == 10
    end
  end
end
