defmodule AlexClaw.Workflows.ExecutorTest do
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Workflows
  alias AlexClaw.Workflows.Executor
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    Sandbox.mode(AlexClaw.Repo, {:shared, self()})
    :ok
  end

  defp create_workflow(attrs \\ %{}) do
    default = %{name: "Test Workflow #{System.unique_integer([:positive])}", enabled: true}
    {:ok, wf} = Workflows.create_workflow(Map.merge(default, attrs))
    wf
  end

  describe "run/1" do
    test "returns error for disabled workflow" do
      wf = create_workflow(%{enabled: false})
      assert {:error, :workflow_disabled} = Executor.run(wf.id)
    end

    test "executes workflow with no steps" do
      wf = create_workflow()
      {:ok, run} = Executor.run(wf.id)
      assert run.status == "completed"
    end

    test "executes a single skill step" do
      bypass = Bypass.open()

      Bypass.expect(bypass, "GET", "/data", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"value": 42}))
      end)

      wf = create_workflow()

      {:ok, _step} =
        Workflows.add_step(wf, %{
          name: "Fetch Data",
          skill: "api_request",
          config: %{"url" => "http://localhost:#{bypass.port}/data", "method" => "GET"}
        })

      {:ok, run} = Executor.run(wf.id)
      assert run.status == "completed"
      assert run.step_results["1"]["name"] == "Fetch Data"
    end

    test "chains steps — second step receives first step output" do
      bypass = Bypass.open()

      Bypass.expect(bypass, "GET", "/step1", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.resp(200, "step1 output")
      end)

      Bypass.expect(bypass, "GET", "/step2", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.resp(200, "step2 output")
      end)

      wf = create_workflow()

      {:ok, _s1} =
        Workflows.add_step(wf, %{
          name: "Step 1",
          skill: "api_request",
          config: %{"url" => "http://localhost:#{bypass.port}/step1", "method" => "GET"}
        })

      {:ok, _s2} =
        Workflows.add_step(wf, %{
          name: "Step 2",
          skill: "api_request",
          config: %{"url" => "http://localhost:#{bypass.port}/step2", "method" => "GET"}
        })

      {:ok, run} = Executor.run(wf.id)
      assert run.status == "completed"
      assert run.step_results["1"]["name"] == "Step 1"
      assert run.step_results["2"]["name"] == "Step 2"
    end

    # A skill that existed when the step was saved can be gone at run time (a
    # dynamic skill unloaded later). Saving such a step is refused since
    # 0.3.54, so the step is written the way an older row looks: past the
    # changeset.
    test "fails on a skill that no longer exists at run time" do
      wf = create_workflow()

      AlexClaw.Repo.insert!(%AlexClaw.Workflows.WorkflowStep{
        workflow_id: wf.id,
        name: "Bad Step",
        skill: "nonexistent_skill",
        position: 1,
        config: %{}
      })

      {:error, run} = Executor.run(wf.id)
      assert run.status == "failed"
      assert run.error =~ "unknown_skill"
    end

    # A step that fails for real: a refused connection (port 9, discard).
    test "records step results on failure" do
      wf = create_workflow()

      {:ok, _step} =
        Workflows.add_step(wf, %{
          name: "Will Fail",
          skill: "api_request",
          config: %{"url" => "http://127.0.0.1:9/"}
        })

      {:error, run} = Executor.run(wf.id)
      assert run.step_results["1"]["name"] == "Will Fail"
      assert run.step_results["1"]["error"]
    end

    test "prompt_template step fails gracefully without LLM" do
      wf = create_workflow()

      {:ok, _step} =
        Workflows.add_step(wf, %{
          name: "LLM Step",
          skill: "llm_transform",
          prompt_template: "Summarize: {input}",
          llm_tier: "light"
        })

      {:error, run} = Executor.run(wf.id)
      assert run.status == "failed"
    end
  end
end
