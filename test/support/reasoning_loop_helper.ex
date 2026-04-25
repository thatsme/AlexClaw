defmodule AlexClawTest.ReasoningLoopHelper do
  @moduledoc false

  @doc """
  Insert the test echo skill directly into the SkillRegistry ETS table.

  The registry is started by the application supervisor; this side-steps the
  GenServer-based registration path so tests don't need a dynamic-skill file
  on disk.
  """
  def register_echo_skill(name \\ "test_echo") do
    module = AlexClawTest.Skills.EchoSkill

    case :ets.info(:skill_registry) do
      :undefined ->
        :ok

      _ ->
        :ets.insert(
          :skill_registry,
          {name, module, :core, :all, [:on_success, :on_error], false}
        )
    end

    name
  end

  def unregister_echo_skill(name \\ "test_echo") do
    case :ets.info(:skill_registry) do
      :undefined -> :ok
      _ -> :ets.delete(:skill_registry, name)
    end
  end

  @doc "Encode a planning-phase response."
  def plan_response(steps, working_memory \\ "wm") when is_list(steps) do
    Jason.encode!(%{"steps" => steps, "working_memory" => working_memory})
  end

  @doc "Encode an execution-phase response."
  def execution_response(input, working_memory \\ "wm") do
    Jason.encode!(%{"input" => input, "working_memory" => working_memory})
  end

  @doc "Encode an evaluation-phase response. quality: 'good' | 'partial' | 'failed'."
  def evaluation_response(quality, working_memory \\ "wm")
      when quality in ["good", "partial", "failed"] do
    Jason.encode!(%{"quality" => quality, "working_memory" => working_memory})
  end

  @doc """
  Encode a decision-phase response. Action one of: continue, adjust, ask_user, done, stuck.
  Optional keys: :confidence, :final_answer, :new_plan, :question, :wm.
  """
  def decision_response(action, opts \\ [])
      when action in ["continue", "adjust", "ask_user", "done", "stuck"] do
    base = %{"action" => action, "working_memory" => Keyword.get(opts, :wm, "wm")}

    base
    |> maybe_put("confidence", Keyword.get(opts, :confidence))
    |> maybe_put("final_answer", Keyword.get(opts, :final_answer))
    |> maybe_put("new_plan", Keyword.get(opts, :new_plan))
    |> maybe_put("question", Keyword.get(opts, :question))
    |> Jason.encode!()
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

  @doc "Build a single plan step targeting EchoSkill."
  def echo_step(input_description \\ "echo something") do
    %{"skill" => "test_echo", "input_description" => input_description}
  end

  @doc "Mint a unique goal string so global Loop names don't collide across tests."
  def unique_goal(prefix \\ "test-goal") do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  @doc "Wait for a Loop GenServer registered as {:global, {Loop, goal}} to terminate."
  def await_loop_done(pid, timeout \\ 5_000) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      timeout -> {:error, :timeout}
    end
  end
end
