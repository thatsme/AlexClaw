defmodule AlexClaw.Workflows.ExecutorTruthTest do
  @moduledoc """
  A run reports what happened (reports/WORKFLOW_LIFECYCLE_REVIEW.md, cause 1).

  Runs ended `completed` when they had not: a route to a step that no longer
  exists, a branch no route handled, an error handled by an `on_error` route.
  A step that raised escaped the executor, and the run stayed `running`.

  The rule, the same whether a step has routes or not:
  - an unrouted branch does what its kind implies: an error FAILS the run;
    `on_empty` ends it `completed` (nothing to do); any other branch goes to
    the next step — what the UI's "Next step (default)" already says;
  - only an explicit `"end"` route or walking past the last step completes a
    run; a route to a position that does not exist FAILS it;
  - a run in which an error was handled by an `on_error` route ends
    `recovered`, not `completed`;
  - every failure names the step: `run.error` contains the step's name;
  - a step that raises fails the run like any other error — the caller gets
    `{:error, run}`, never an exception, and no run is left `running`.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Workflows
  alias AlexClaw.Workflows.Executor
  alias AlexClawTest.ReasoningLoopHelper
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    Sandbox.mode(AlexClaw.Repo, {:shared, self()})
    bypass = Bypass.open()
    Bypass.stub(bypass, "GET", "/ok", fn conn -> Plug.Conn.resp(conn, 200, "ok") end)
    %{url: "http://localhost:#{bypass.port}/ok"}
  end

  defp workflow do
    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "Truth #{System.unique_integer([:positive])}",
        enabled: true
      })

    wf
  end

  defp step(wf, attrs), do: {:ok, _} = Workflows.add_step(wf, attrs)

  describe "a route to a step that does not exist" do
    test "fails the run, naming the step and the target", %{url: url} do
      wf = workflow()

      step(wf, %{
        name: "Fetch",
        skill: "api_request",
        config: %{"url" => url},
        routes: [%{"branch" => "on_2xx", "goto" => 7}]
      })

      assert {:error, run} = Executor.run(wf.id)
      assert run.status == "failed"
      assert run.error =~ "Fetch"
      assert run.error =~ "7"
    end
  end

  describe "an unrouted branch" do
    # A real failure: a refused connection (port 9, discard). Since 0.3.54 a
    # step for a skill that does not exist cannot be saved.
    test "an error with no on_error route fails the run, naming the step" do
      wf = workflow()

      step(wf, %{
        name: "Broken",
        skill: "api_request",
        config: %{"url" => "http://127.0.0.1:9/"},
        routes: [%{"branch" => "on_2xx", "goto" => "end"}]
      })

      assert {:error, run} = Executor.run(wf.id)
      assert run.status == "failed"
      assert run.error =~ "Broken"
    end

    test "a non-error branch goes to the next step", %{url: url} do
      wf = workflow()

      # on_2xx is not routed: it goes on, it does not end the run.
      step(wf, %{
        name: "Fetch",
        skill: "api_request",
        config: %{"url" => url},
        routes: [%{"branch" => "on_4xx", "goto" => "end"}]
      })

      step(wf, %{name: "Next", skill: "api_request", config: %{"url" => url}})

      assert {:ok, run} = Executor.run(wf.id)
      assert run.status == "completed"
      assert run.step_results["2"]["name"] == "Next"
    end
  end

  describe "an error handled by on_error" do
    test "ends the run recovered, not completed", %{url: url} do
      wf = workflow()

      step(wf, %{
        name: "Will Fail",
        skill: "api_request",
        config: %{"url" => "http://127.0.0.1:9/"},
        routes: [%{"branch" => "on_error", "goto" => 2}]
      })

      step(wf, %{name: "Recover", skill: "api_request", config: %{"url" => url}})

      assert {:ok, run} = Executor.run(wf.id)
      assert run.status == "recovered"
      assert run.step_results["1"]["name"] == "Will Fail"
      assert run.step_results["2"]["name"] == "Recover"
    end
  end

  describe "explicit ends still complete" do
    test "an \"end\" route completes the run", %{url: url} do
      wf = workflow()

      step(wf, %{
        name: "Only",
        skill: "api_request",
        config: %{"url" => url},
        routes: [%{"branch" => "on_2xx", "goto" => "end"}]
      })

      step(wf, %{name: "Never", skill: "api_request", config: %{"url" => url}})

      assert {:ok, run} = Executor.run(wf.id)
      assert run.status == "completed"
      refute Map.has_key?(run.step_results, "2")
    end
  end

  describe "a step that raises" do
    setup do
      echo = ReasoningLoopHelper.register_echo_skill()
      on_exit(fn -> ReasoningLoopHelper.unregister_echo_skill(echo) end)
      %{echo: echo}
    end

    test "fails the run instead of escaping the executor", %{echo: echo} do
      wf = workflow()
      step(wf, %{name: "Explodes", skill: echo})

      # The echo skill raises when its input contains "raise".
      result = Executor.run_with_initial_input(wf.id, "raise")

      assert {:error, run} = result
      assert run.status == "failed"
      assert run.error =~ "Explodes"

      stored = Workflows.get_run!(run.id)
      assert stored.status == "failed", "the run was left #{stored.status}"
    end
  end
end
