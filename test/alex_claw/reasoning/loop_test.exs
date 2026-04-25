defmodule AlexClaw.Reasoning.LoopTest do
  @moduledoc """
  Integration tests for `AlexClaw.Reasoning.Loop`.

  Loop spawns Tasks for each LLM call, so Mox runs in global mode and the
  test case is `async: false`. Each phase is dispatched on the system prompt
  passed via `LLM.complete(prompt, system: ...)` — the most reliable seam.

  Assertions target the `:session_complete` broadcast on `"reasoning:loop"`,
  which is the contract `AdminLive.Chat` subscribes to. Where DB consistency
  is part of the contract (the happy path, abort), the persisted session row
  is also asserted.
  """

  use AlexClaw.DataCase, async: false

  import Mox
  import AlexClawTest.ReasoningLoopHelper

  alias AlexClaw.LLM
  alias AlexClaw.Reasoning
  alias AlexClaw.Reasoning.Loop

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    prior_impl = Application.get_env(:alex_claw, :llm_impl)
    Application.put_env(:alex_claw, :llm_impl, LLM.Mock)

    register_echo_skill()

    Mox.stub(LLM.Mock, :embed, fn _text, _opts ->
      {:ok, List.duplicate(0.0, 768)}
    end)

    counter_table = :"loop_test_counters_#{System.unique_integer([:positive])}"
    :ets.new(counter_table, [:public, :named_table])

    :ok = Phoenix.PubSub.subscribe(AlexClaw.PubSub, "reasoning:loop")

    on_exit(fn ->
      unregister_echo_skill()

      if :ets.info(counter_table) != :undefined do
        :ets.delete(counter_table)
      end

      if prior_impl do
        Application.put_env(:alex_claw, :llm_impl, prior_impl)
      else
        Application.delete_env(:alex_claw, :llm_impl)
      end
    end)

    {:ok, counter_table: counter_table}
  end

  defp default_opts(extra \\ []) do
    Keyword.merge(
      [
        skill_whitelist: ["test_echo"],
        max_iterations: 5,
        stuck_threshold: 3,
        time_budget_ms: 30_000,
        step_timeout_ms: 5_000,
        delivery: ["memory"],
        done_confidence_threshold: 0.7
      ],
      extra
    )
  end

  defp phase_from_system(opts) do
    case Keyword.get(opts, :system, "") do
      "You are a task planning" <> _ -> :planning
      "You are preparing skill input" <> _ -> :execution
      "You are evaluating a skill" <> _ -> :evaluation
      "You are a decision-making" <> _ -> :decision
      "You are a context compressor" <> _ -> :compression
      "You are producing a final answer" <> _ -> :forced_summary
      _ -> :unknown
    end
  end

  defp counter_inc(table, key) do
    :ets.update_counter(table, key, 1, {key, 0})
  end

  defp wait_for_complete(timeout) do
    receive do
      {:session_complete, %{status: status}} -> {:ok, status}
    after
      timeout -> {:error, :timeout}
    end
  end

  defp find_session_by_goal(goal) do
    Reasoning.list_sessions()
    |> Enum.find(&(&1.goal == goal))
  end

  describe "happy path" do
    test "single-step plan + good eval triggers forced summary; broadcasts fire in order" do
      goal = unique_goal("happy")

      Mox.stub(LLM.Mock, :complete, fn _prompt, opts ->
        case phase_from_system(opts) do
          :planning -> {:ok, plan_response([echo_step("hello")])}
          :execution -> {:ok, execution_response("hello world")}
          :evaluation -> {:ok, evaluation_response("good")}
          :forced_summary -> {:ok, ~s|{"answer": "task complete", "working_memory": "done"}|}
          other -> flunk("Unexpected LLM phase: #{inspect(other)}")
        end
      end)

      {:ok, pid} = Loop.start(goal, default_opts())
      assert :ok = await_loop_done(pid, 10_000)

      assert_received {:session_started, %{goal: ^goal}}
      assert_received {:phase_change, %{phase: :planning}}
      assert_received {:plan_ready, %{steps: [_ | _]}}
      assert_received {:phase_change, %{phase: :executing}}
      assert_received {:phase_change, %{phase: :evaluating}}
      assert_received {:evaluation_done, %{quality: "good"}}
      assert_received {:phase_change, %{phase: :deciding}}
      assert_received {:session_complete, %{status: :completed, result: result}}
      assert result =~ "task complete"

      # Regression: terminate/2 used to overwrite the row with "failed" on
      # normal stop because it read state.session.status (stale) instead of
      # the DB. The persisted row must match the broadcast.
      session = find_session_by_goal(goal)
      assert session.status == "completed"
      assert session.result =~ "task complete"
    end
  end

  describe "human-in-the-loop" do
    test "ask_user → steer → :resuming → re-plan → completion", %{counter_table: ct} do
      goal = unique_goal("steer-replan")
      :ets.insert(ct, {:plan, 0})
      :ets.insert(ct, {:eval, 0})

      Mox.stub(LLM.Mock, :complete, fn _prompt, opts ->
        case phase_from_system(opts) do
          :planning ->
            n = counter_inc(ct, :plan)
            steps = if n == 1, do: [echo_step("first")], else: [echo_step("after_steer")]
            {:ok, plan_response(steps)}

          :execution ->
            {:ok, execution_response("payload")}

          :evaluation ->
            n = counter_inc(ct, :eval)
            quality = if n == 1, do: "partial", else: "good"
            {:ok, evaluation_response(quality)}

          :decision ->
            {:ok, decision_response("ask_user", question: "Need clarification")}

          :forced_summary ->
            {:ok, ~s|{"answer": "done after steer", "working_memory": "wm"}|}

          other ->
            flunk("Unexpected LLM phase: #{inspect(other)}")
        end
      end)

      {:ok, pid} = Loop.start(goal, default_opts())

      assert_receive {:waiting_user, %{question: "Need clarification"}}, 10_000

      Loop.steer(pid, "use the second approach")

      assert_receive {:user_steer, %{guidance: "use the second approach"}}, 2_000
      assert_receive {:phase_change, %{phase: :resuming}}, 2_000
      assert_receive {:phase_change, %{phase: :planning}}, 2_000

      assert :ok = await_loop_done(pid, 15_000)
      assert {:ok, :completed} = wait_for_complete(2_000)

      [{:plan, plan_count}] = :ets.lookup(ct, :plan)
      assert plan_count == 2

      session = find_session_by_goal(goal)
      assert session.status == "completed"
      assert session.result =~ "done after steer"
    end

    test "ask_user → add_context → resume → :resuming → re-plan → completion", %{
      counter_table: ct
    } do
      goal = unique_goal("respond-replan")
      :ets.insert(ct, {:plan, 0})
      :ets.insert(ct, {:eval, 0})

      Mox.stub(LLM.Mock, :complete, fn _prompt, opts ->
        case phase_from_system(opts) do
          :planning ->
            n = counter_inc(ct, :plan)
            steps = if n == 1, do: [echo_step("first")], else: [echo_step("after_resume")]
            {:ok, plan_response(steps)}

          :execution ->
            {:ok, execution_response("payload")}

          :evaluation ->
            n = counter_inc(ct, :eval)
            quality = if n == 1, do: "partial", else: "good"
            {:ok, evaluation_response(quality)}

          :decision ->
            {:ok, decision_response("ask_user", question: "Need clarification")}

          :forced_summary ->
            {:ok, ~s|{"answer": "done after resume", "working_memory": "wm"}|}

          other ->
            flunk("Unexpected LLM phase: #{inspect(other)}")
        end
      end)

      {:ok, pid} = Loop.start(goal, default_opts())

      assert_receive {:waiting_user, %{question: "Need clarification"}}, 10_000

      Loop.add_context(pid, "the answer is 42")
      assert_receive {:context_added, _}, 2_000
      Loop.resume(pid)

      assert_receive {:phase_change, %{phase: :resuming}}, 2_000
      assert_receive {:phase_change, %{phase: :planning}}, 2_000

      assert :ok = await_loop_done(pid, 15_000)
      assert {:ok, :completed} = wait_for_complete(2_000)

      [{:plan, plan_count}] = :ets.lookup(ct, :plan)
      assert plan_count == 2

      session = find_session_by_goal(goal)
      assert session.status == "completed"
      assert session.result =~ "done after resume"
    end
  end

  describe "failure paths" do
    test "evaluation 'failed' triggers LLM decision" do
      goal = unique_goal("eval-fail-done")

      Mox.stub(LLM.Mock, :complete, fn _prompt, opts ->
        case phase_from_system(opts) do
          :planning -> {:ok, plan_response([echo_step("step1"), echo_step("step2")])}
          :execution -> {:ok, execution_response("payload")}
          :evaluation -> {:ok, evaluation_response("failed")}
          :decision ->
            {:ok, decision_response("done", confidence: 0.9, final_answer: "giving up")}
          :forced_summary -> {:ok, ~s|{"answer": "x", "working_memory": "wm"}|}
          other -> flunk("Unexpected LLM phase: #{inspect(other)}")
        end
      end)

      {:ok, pid} = Loop.start(goal, default_opts())
      assert :ok = await_loop_done(pid, 15_000)

      assert {:ok, status} = wait_for_complete(2_000)
      assert status in [:completed, :stuck]
    end

    test "malformed planning JSON exhausts retries" do
      goal = unique_goal("malformed-plan")

      Mox.stub(LLM.Mock, :complete, fn _prompt, opts ->
        case phase_from_system(opts) do
          :planning -> {:ok, "not JSON at all { broken"}
          _ -> {:ok, ~s|{"answer": "x", "working_memory": "wm"}|}
        end
      end)

      {:ok, pid} = Loop.start(goal, default_opts(stuck_threshold: 2))
      assert :ok = await_loop_done(pid, 15_000)

      assert {:ok, status} = wait_for_complete(2_000)
      assert status in [:stuck, :failed]
    end

    test "max_iterations cap terminates the loop" do
      goal = unique_goal("max-iter")

      Mox.stub(LLM.Mock, :complete, fn _prompt, opts ->
        case phase_from_system(opts) do
          :planning -> {:ok, plan_response([echo_step("a"), echo_step("b"), echo_step("c")])}
          :execution -> {:ok, execution_response("payload")}
          :evaluation -> {:ok, evaluation_response("partial")}
          :decision -> {:ok, decision_response("continue")}
          :forced_summary -> {:ok, ~s|{"answer": "x", "working_memory": "wm"}|}
          other -> flunk("Unexpected LLM phase: #{inspect(other)}")
        end
      end)

      {:ok, pid} = Loop.start(goal, default_opts(max_iterations: 2))
      assert :ok = await_loop_done(pid, 15_000)

      assert {:ok, status} = wait_for_complete(2_000)
      assert status in [:failed, :stuck]
    end

    test "plan with skill not in whitelist is rejected" do
      goal = unique_goal("whitelist-reject")

      Mox.stub(LLM.Mock, :complete, fn _prompt, opts ->
        case phase_from_system(opts) do
          :planning ->
            {:ok, plan_response([%{"skill" => "nonexistent_skill", "input_description" => "won't"}])}
          _ ->
            {:ok, ~s|{"answer": "x", "working_memory": "wm"}|}
        end
      end)

      {:ok, pid} = Loop.start(goal, default_opts(stuck_threshold: 2))
      assert :ok = await_loop_done(pid, 15_000)

      assert {:ok, status} = wait_for_complete(2_000)
      assert status in [:stuck, :failed]
    end
  end

  describe "intervention" do
    test "abort during execution terminates with :aborted broadcast" do
      goal = unique_goal("abort")
      test_pid = self()

      Mox.stub(LLM.Mock, :complete, fn _prompt, opts ->
        case phase_from_system(opts) do
          :planning -> {:ok, plan_response([echo_step("step1"), echo_step("step2")])}
          :execution ->
            send(test_pid, :execution_started)
            Process.sleep(500)
            {:ok, execution_response("payload")}
          :evaluation -> {:ok, evaluation_response("good")}
          :decision -> {:ok, decision_response("done", confidence: 0.9, final_answer: "x")}
          :forced_summary -> {:ok, ~s|{"answer": "x", "working_memory": "wm"}|}
          other -> flunk("Unexpected LLM phase: #{inspect(other)}")
        end
      end)

      {:ok, pid} = Loop.start(goal, default_opts())
      assert_receive :execution_started, 10_000

      Loop.abort(pid)
      assert :ok = await_loop_done(pid, 5_000)

      assert {:ok, :aborted} = wait_for_complete(2_000)

      session = find_session_by_goal(goal)
      assert session.status == "aborted"
    end
  end

  describe "working memory compression" do
    test "compression triggers when iteration % 3 == 0 and working memory is large", %{
      counter_table: ct
    } do
      goal = unique_goal("compression")
      large_wm = String.duplicate("noise ", 200)
      test_pid = self()
      :ets.insert(ct, {:dec, 0})

      Mox.stub(LLM.Mock, :complete, fn _prompt, opts ->
        case phase_from_system(opts) do
          :planning ->
            {:ok, plan_response([echo_step("a"), echo_step("b"), echo_step("c")])}

          :execution ->
            {:ok, execution_response("payload", large_wm)}

          :evaluation ->
            {:ok, evaluation_response("partial", large_wm)}

          :decision ->
            n = counter_inc(ct, :dec)
            if n < 2 do
              {:ok, decision_response("continue")}
            else
              {:ok, decision_response("done", confidence: 0.9, final_answer: "compressed result")}
            end

          :compression ->
            send(test_pid, :compression_called)
            {:ok, ~s|{"compressed": "summary"}|}

          :forced_summary ->
            {:ok, ~s|{"answer": "x", "working_memory": "wm"}|}

          other ->
            flunk("Unexpected LLM phase: #{inspect(other)}")
        end
      end)

      {:ok, pid} = Loop.start(goal, default_opts(max_iterations: 5))
      assert_receive :compression_called, 15_000
      assert :ok = await_loop_done(pid, 15_000)
    end
  end
end
