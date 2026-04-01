defmodule AlexClaw.ReasoningTest do
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Reasoning

  # --- Sessions CRUD ---

  describe "create_session/1" do
    test "creates a session with valid goal" do
      assert {:ok, session} = Reasoning.create_session(%{goal: "Research Elixir GenServer patterns"})
      assert session.goal == "Research Elixir GenServer patterns"
      assert session.status == "planning"
      assert session.iteration_count == 0
      assert session.total_llm_calls == 0
    end

    test "rejects session without goal" do
      assert {:error, changeset} = Reasoning.create_session(%{})
      assert errors_on(changeset)[:goal]
    end

    test "rejects session with invalid status" do
      assert {:error, changeset} = Reasoning.create_session(%{goal: "test", status: "invalid"})
      assert errors_on(changeset)[:status]
    end

    test "rejects session with confidence out of range" do
      assert {:error, changeset} = Reasoning.create_session(%{goal: "test", confidence: 1.5})
      assert errors_on(changeset)[:confidence]
    end

    test "rejects session with negative confidence" do
      assert {:error, changeset} = Reasoning.create_session(%{goal: "test", confidence: -0.1})
      assert errors_on(changeset)[:confidence]
    end

    test "rejects session with negative iteration_count" do
      assert {:error, changeset} = Reasoning.create_session(%{goal: "test", iteration_count: -1})
      assert errors_on(changeset)[:iteration_count]
    end

    test "creates session with all optional fields" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      attrs = %{
        goal: "full test",
        status: "executing",
        plan: %{"steps" => [%{"step" => 1}]},
        working_memory: "context here",
        config: %{max_iterations: 10},
        delivery_config: %{channels: ["memory"]},
        confidence: 0.5,
        iteration_count: 3,
        total_llm_calls: 12,
        started_at: now
      }

      assert {:ok, session} = Reasoning.create_session(attrs)
      assert session.working_memory == "context here"
      assert session.confidence == 0.5
    end
  end

  describe "get_session/1" do
    test "returns session with steps preloaded" do
      {:ok, session} = Reasoning.create_session(%{goal: "test"})

      Reasoning.record_step(%{
        session_id: session.id,
        iteration: 1,
        phase: "plan"
      })

      assert {:ok, found} = Reasoning.get_session(session.id)
      assert found.id == session.id
      assert length(found.steps) == 1
    end

    test "returns not_found for nonexistent id" do
      assert {:error, :not_found} = Reasoning.get_session(999_999)
    end

    test "returns not_found for 0" do
      assert {:error, :not_found} = Reasoning.get_session(0)
    end
  end

  describe "active_session/0" do
    test "returns nil when no active sessions" do
      assert Reasoning.active_session() == nil
    end

    test "returns the active session" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      {:ok, _} = Reasoning.create_session(%{goal: "active", status: "executing", started_at: now})
      assert %{goal: "active"} = Reasoning.active_session()
    end

    test "does not return completed sessions" do
      {:ok, session} = Reasoning.create_session(%{goal: "done"})
      Reasoning.mark_completed(session, "result", 0.9)
      assert Reasoning.active_session() == nil
    end

    test "does not return aborted sessions" do
      {:ok, session} = Reasoning.create_session(%{goal: "aborted"})
      Reasoning.mark_aborted(session)
      assert Reasoning.active_session() == nil
    end
  end

  describe "update_session/2" do
    test "updates session fields" do
      {:ok, session} = Reasoning.create_session(%{goal: "test"})
      assert {:ok, updated} = Reasoning.update_session(session, %{status: "paused", working_memory: "paused state"})
      assert updated.status == "paused"
      assert updated.working_memory == "paused state"
    end
  end

  describe "mark_completed/3" do
    test "sets status, result, confidence, and completed_at" do
      {:ok, session} = Reasoning.create_session(%{goal: "test"})
      assert {:ok, completed} = Reasoning.mark_completed(session, "The answer", 0.85)
      assert completed.status == "completed"
      assert completed.result == "The answer"
      assert completed.confidence == 0.85
      assert completed.completed_at
    end
  end

  describe "mark_stuck/2" do
    test "sets status and error" do
      {:ok, session} = Reasoning.create_session(%{goal: "test"})
      assert {:ok, stuck} = Reasoning.mark_stuck(session, "3 consecutive failures")
      assert stuck.status == "stuck"
      assert stuck.error == "3 consecutive failures"
    end
  end

  describe "mark_failed/2" do
    test "sets status and error" do
      {:ok, session} = Reasoning.create_session(%{goal: "test"})
      assert {:ok, failed} = Reasoning.mark_failed(session, "time budget exceeded")
      assert failed.status == "failed"
      assert failed.error == "time budget exceeded"
    end
  end

  describe "increment_iteration/1" do
    test "increments iteration_count" do
      {:ok, session} = Reasoning.create_session(%{goal: "test"})
      assert {:ok, updated} = Reasoning.increment_iteration(session)
      assert updated.iteration_count == 1
    end
  end

  describe "increment_llm_calls/1" do
    test "increments total_llm_calls" do
      {:ok, session} = Reasoning.create_session(%{goal: "test"})
      assert {:ok, updated} = Reasoning.increment_llm_calls(session)
      assert updated.total_llm_calls == 1
    end
  end

  # --- Steps ---

  describe "record_step/1" do
    test "records a step with valid attributes" do
      {:ok, session} = Reasoning.create_session(%{goal: "test"})

      assert {:ok, step} =
               Reasoning.record_step(%{
                 session_id: session.id,
                 iteration: 1,
                 phase: "plan",
                 llm_prompt: "prompt text",
                 llm_response: "response text",
                 duration_ms: 1500
               })

      assert step.phase == "plan"
      assert step.duration_ms == 1500
    end

    test "rejects step with invalid phase" do
      {:ok, session} = Reasoning.create_session(%{goal: "test"})

      assert {:error, changeset} =
               Reasoning.record_step(%{
                 session_id: session.id,
                 iteration: 1,
                 phase: "invalid_phase"
               })

      assert errors_on(changeset)[:phase]
    end

    test "rejects step without session_id" do
      assert {:error, changeset} = Reasoning.record_step(%{iteration: 1, phase: "plan"})
      assert errors_on(changeset)[:session_id]
    end

    test "rejects step with invalid decision value" do
      {:ok, session} = Reasoning.create_session(%{goal: "test"})

      assert {:error, changeset} =
               Reasoning.record_step(%{
                 session_id: session.id,
                 iteration: 1,
                 phase: "decide",
                 decision: "invalid_decision"
               })

      assert errors_on(changeset)[:decision]
    end

    test "accepts valid decision values" do
      {:ok, session} = Reasoning.create_session(%{goal: "test"})

      for decision <- ~w(continue adjust ask_user done stuck) do
        assert {:ok, step} =
                 Reasoning.record_step(%{
                   session_id: session.id,
                   iteration: 1,
                   phase: "decide",
                   decision: decision
                 })

        assert step.decision == decision
      end
    end

    test "rejects step with negative duration_ms" do
      {:ok, session} = Reasoning.create_session(%{goal: "test"})

      assert {:error, changeset} =
               Reasoning.record_step(%{
                 session_id: session.id,
                 iteration: 1,
                 phase: "execute",
                 duration_ms: -100
               })

      assert errors_on(changeset)[:duration_ms]
    end

    test "rejects step with confidence out of range" do
      {:ok, session} = Reasoning.create_session(%{goal: "test"})

      assert {:error, changeset} =
               Reasoning.record_step(%{
                 session_id: session.id,
                 iteration: 1,
                 phase: "decide",
                 confidence: 2.0
               })

      assert errors_on(changeset)[:confidence]
    end

    test "rejects step with iteration 0" do
      {:ok, session} = Reasoning.create_session(%{goal: "test"})

      assert {:error, changeset} =
               Reasoning.record_step(%{
                 session_id: session.id,
                 iteration: 0,
                 phase: "plan"
               })

      assert errors_on(changeset)[:iteration]
    end
  end

  describe "list_steps/1" do
    test "returns steps ordered by iteration and inserted_at" do
      {:ok, session} = Reasoning.create_session(%{goal: "test"})

      Reasoning.record_step(%{session_id: session.id, iteration: 2, phase: "execute"})
      Reasoning.record_step(%{session_id: session.id, iteration: 1, phase: "plan"})
      Reasoning.record_step(%{session_id: session.id, iteration: 1, phase: "execute"})

      steps = Reasoning.list_steps(session.id)
      assert length(steps) == 3
      assert Enum.at(steps, 0).iteration == 1
      assert Enum.at(steps, 0).phase == "plan"
    end

    test "returns empty list for session with no steps" do
      {:ok, session} = Reasoning.create_session(%{goal: "test"})
      assert Reasoning.list_steps(session.id) == []
    end

    test "returns empty list for nonexistent session" do
      assert Reasoning.list_steps(999_999) == []
    end
  end

  describe "latest_step/1" do
    test "returns most recent step" do
      {:ok, session} = Reasoning.create_session(%{goal: "test"})
      Reasoning.record_step(%{session_id: session.id, iteration: 1, phase: "plan"})
      Reasoning.record_step(%{session_id: session.id, iteration: 1, phase: "execute", skill_name: "web_search"})

      latest = Reasoning.latest_step(session.id)
      assert latest.phase == "execute"
      assert latest.skill_name == "web_search"
    end

    test "returns nil for session with no steps" do
      {:ok, session} = Reasoning.create_session(%{goal: "test"})
      assert Reasoning.latest_step(session.id) == nil
    end
  end

  describe "delete_session/1" do
    test "deletes session and cascades to steps" do
      {:ok, session} = Reasoning.create_session(%{goal: "test"})
      Reasoning.record_step(%{session_id: session.id, iteration: 1, phase: "plan"})

      assert {:ok, _} = Reasoning.delete_session(session)
      assert {:error, :not_found} = Reasoning.get_session(session.id)
      assert Reasoning.list_steps(session.id) == []
    end
  end

  # --- Helper ---

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
