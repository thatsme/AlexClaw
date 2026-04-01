defmodule AlexClaw.Reasoning.Loop do
  @moduledoc """
  GenServer implementing the reasoning loop state machine.

  Phases: planning → executing → evaluating → deciding → (loop or terminate)

  LLM calls run as Tasks to keep the GenServer responsive to intervention
  messages (pause, abort, steer) during slow local model inference.
  """

  use GenServer
  require Logger

  alias AlexClaw.{Config, LLM, Memory, Knowledge}
  alias AlexClaw.Reasoning
  alias AlexClaw.Reasoning.{Prompts, PromptParser, SkillExecutor}

  @pubsub AlexClaw.PubSub
  @topic "reasoning:loop"

  # --- State ---

  defmodule State do
    @moduledoc false
    defstruct [
      :session_id,
      :session,
      :goal,
      :plan,
      :current_step_index,
      :iteration,
      :status,
      :config,
      :started_at,
      :working_memory,
      :user_guidance,
      :task_ref,
      :pending_result,
      :time_budget_ref,
      consecutive_failures: 0,
      total_llm_calls: 0,
      recent_actions: []
    ]
  end

  # --- Client API ---

  @spec start(String.t(), keyword()) :: {:ok, pid()} | {:error, any()}
  def start(goal, opts \\ []) do
    case Reasoning.active_session() do
      nil ->
        DynamicSupervisor.start_child(
          AlexClaw.Reasoning.Supervisor,
          {__MODULE__, {goal, opts}}
        )

      _active ->
        {:error, :session_already_active}
    end
  end

  @spec pause(pid()) :: :ok
  def pause(pid), do: GenServer.cast(pid, :pause)

  @spec resume(pid()) :: :ok
  def resume(pid), do: GenServer.cast(pid, :resume)

  @spec abort(pid()) :: :ok
  def abort(pid), do: GenServer.cast(pid, :abort)

  @spec steer(pid(), String.t()) :: :ok
  def steer(pid, guidance), do: GenServer.cast(pid, {:steer, guidance})

  @spec add_context(pid(), String.t()) :: :ok
  def add_context(pid, context), do: GenServer.cast(pid, {:add_context, context})

  @spec override_step(pid(), String.t(), String.t()) :: :ok
  def override_step(pid, skill_name, input), do: GenServer.cast(pid, {:override_step, skill_name, input})

  @spec status(pid()) :: map()
  def status(pid), do: GenServer.call(pid, :status)

  # --- GenServer Callbacks ---

  def child_spec({goal, opts}) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [{goal, opts}]},
      restart: :transient,
      shutdown: 10_000
    }
  end

  def start_link({goal, opts}) do
    GenServer.start_link(__MODULE__, {goal, opts}, name: {:global, {__MODULE__, goal}})
  end

  @impl true
  def init({goal, opts}) do
    config = build_config(opts)

    case create_session(goal, config) do
      {:ok, session} ->
        state = %State{
          session_id: session.id,
          session: session,
          goal: goal,
          plan: [],
          current_step_index: 0,
          iteration: 1,
          status: :planning,
          config: config,
          started_at: System.monotonic_time(:millisecond),
          working_memory: "",
          user_guidance: nil,
          consecutive_failures: 0,
          total_llm_calls: 0,
          recent_actions: []
        }

        # Set time budget hard kill timer
        time_budget_ref =
          Process.send_after(self(), :time_budget_exceeded, config.time_budget_ms)

        state = %{state | time_budget_ref: time_budget_ref}

        broadcast(:session_started, %{session_id: session.id, goal: goal})
        {:ok, state, {:continue, :start_planning}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:start_planning, state) do
    state = %{state | status: :planning}
    update_session_status(state, "planning")
    broadcast(:phase_change, phase_data(state, :planning))

    task = spawn_llm_task(fn -> run_planning(state) end)
    {:noreply, %{state | task_ref: task.ref}}
  end

  def handle_continue(:execute_step, state) do
    if check_limits(state) != :ok do
      handle_limit_exceeded(state)
    else
      state = %{state | status: :executing}
      update_session_status(state, "executing")

      step = Enum.at(state.plan, state.current_step_index)

      if step do
        broadcast(:phase_change, phase_data(state, :executing, %{skill: step["skill"]}))
        task = spawn_llm_task(fn -> run_execution(state, step) end)
        {:noreply, %{state | task_ref: task.ref}}
      else
        # No more steps — go to decision
        {:noreply, state, {:continue, :decide}}
      end
    end
  end

  def handle_continue(:evaluate, state) do
    state = %{state | status: :evaluating}
    update_session_status(state, "evaluating")
    broadcast(:phase_change, phase_data(state, :evaluating))

    task = spawn_llm_task(fn -> run_evaluation(state) end)
    {:noreply, %{state | task_ref: task.ref}}
  end

  def handle_continue(:decide, state) do
    state = %{state | status: :deciding}
    update_session_status(state, "deciding")
    broadcast(:phase_change, phase_data(state, :deciding))

    task = spawn_llm_task(fn -> run_decision(state) end)
    {:noreply, %{state | task_ref: task.ref}}
  end

  def handle_continue(:resume, state) do
    case state.pending_result do
      nil ->
        # Resume from where we were
        {:noreply, state, {:continue, resume_phase(state)}}

      {phase, result} ->
        # Process stored result from task that completed during pause
        state = %{state | pending_result: nil}
        handle_phase_result(phase, result, state)
    end
  end

  # --- Intervention Handlers ---

  @impl true
  def handle_cast(:pause, %{status: :paused} = state) do
    {:noreply, state}
  end

  def handle_cast(:pause, state) do
    Logger.info("[ReasoningLoop] Paused at iteration #{state.iteration}, phase #{state.status}")
    state = %{state | status: :paused}
    update_session_status(state, "paused")
    broadcast(:phase_change, phase_data(state, :paused))
    {:noreply, state}
  end

  def handle_cast(:resume, %{status: :paused} = state) do
    Logger.info("[ReasoningLoop] Resuming from pause")
    broadcast(:phase_change, phase_data(state, :resuming))
    {:noreply, state, {:continue, :resume}}
  end

  def handle_cast(:resume, state) do
    {:noreply, state}
  end

  def handle_cast(:abort, state) do
    Logger.info("[ReasoningLoop] Aborted by user")
    shutdown_task(state)
    finish_session(state, :aborted, "Aborted by user")
    {:stop, :normal, state}
  end

  def handle_cast({:steer, guidance}, state) do
    Logger.info("[ReasoningLoop] User steering: #{String.slice(guidance, 0, 100)}")
    state = %{state | user_guidance: "[USER GUIDANCE] #{guidance}"}

    Reasoning.record_step(%{
      session_id: state.session_id,
      iteration: state.iteration,
      phase: "user_override",
      user_guidance: guidance,
      working_memory_snapshot: state.working_memory,
      duration_ms: 0
    })

    broadcast(:user_steer, %{session_id: state.session_id, guidance: guidance})
    {:noreply, state}
  end

  def handle_cast({:add_context, context}, state) do
    updated_wm =
      if state.working_memory == "" do
        "[ADDITIONAL CONTEXT] #{context}"
      else
        "#{state.working_memory}\n[ADDITIONAL CONTEXT] #{context}"
      end

    state = %{state | working_memory: updated_wm}
    persist_working_memory(state)
    broadcast(:context_added, %{session_id: state.session_id})
    {:noreply, state}
  end

  def handle_cast({:override_step, skill_name, input}, state) do
    Logger.info("[ReasoningLoop] User override: #{skill_name}")
    state = %{state | status: :executing}

    task = spawn_llm_task(fn ->
      run_user_override(state, skill_name, input)
    end)

    {:noreply, %{state | task_ref: task.ref}}
  end

  # --- Task Result Handlers ---

  @impl true
  def handle_info({ref, {phase, result}}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | task_ref: nil}

    if state.status == :paused do
      # Store result for when we resume
      {:noreply, %{state | pending_result: {phase, result}}}
    else
      handle_phase_result(phase, result, state)
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
    state = %{state | task_ref: nil}
    Logger.error("[ReasoningLoop] Task crashed: #{inspect(reason)}")

    state = %{state | consecutive_failures: state.consecutive_failures + 1}

    if state.consecutive_failures >= state.config.stuck_threshold do
      finish_session(state, :stuck, "Task process crashed #{state.consecutive_failures} times consecutively")
      {:stop, :normal, state}
    else
      record_error_step(state, "Task crashed: #{inspect(reason)}")
      {:noreply, state, {:continue, :decide}}
    end
  end

  def handle_info(:time_budget_exceeded, state) do
    Logger.warning("[ReasoningLoop] Time budget exceeded")
    shutdown_task(state)
    finish_session(state, :failed, "Time budget exceeded (#{state.config.time_budget_ms}ms)")
    {:stop, :normal, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    reply = %{
      session_id: state.session_id,
      goal: state.goal,
      status: state.status,
      iteration: state.iteration,
      total_llm_calls: state.total_llm_calls,
      consecutive_failures: state.consecutive_failures,
      current_step_index: state.current_step_index,
      plan_length: length(state.plan),
      working_memory: state.working_memory,
      elapsed_ms: System.monotonic_time(:millisecond) - state.started_at
    }

    {:reply, reply, state}
  end

  # --- Phase Execution (runs inside Task) ---

  defp run_planning(state) do
    started = System.monotonic_time(:millisecond)

    prior_knowledge = fetch_prior_knowledge(state.goal)

    skill_list =
      state.config.skill_whitelist
      |> SkillExecutor.list_whitelisted_skills()
      |> Enum.map_join("\n", fn {name, desc} -> "- #{name}: #{desc}" end)

    prompt =
      Prompts.planning(%{
        goal: state.goal,
        skill_list: skill_list,
        working_memory: state.working_memory,
        prior_knowledge: prior_knowledge,
        max_steps: state.config.max_plan_steps
      })

    system = "You are a task planning assistant. Always respond with valid JSON only."

    case call_local_llm(prompt, system) do
      {:ok, raw_response} ->
        duration = System.monotonic_time(:millisecond) - started

        case PromptParser.parse_plan(raw_response) do
          {:ok, parsed} ->
            {:planning, {:ok, parsed, prompt, raw_response, duration}}

          {:error, :parse_failed, reason} ->
            {:planning, {:error, reason, prompt, raw_response, duration}}
        end

      {:error, reason} ->
        duration = System.monotonic_time(:millisecond) - started
        {:planning, {:error, inspect(reason), prompt, nil, duration}}
    end
  end

  defp run_execution(state, step) do
    started = System.monotonic_time(:millisecond)
    skill_name = step["skill"]
    step_desc = step["input_description"] || step["reason"] || ""

    previous_results = summarize_previous_results(state)

    prompt =
      Prompts.execution(%{
        skill_name: skill_name,
        skill_description: SkillExecutor.skill_description(skill_name),
        step_description: step_desc,
        previous_results: previous_results,
        working_memory: state.working_memory,
        user_guidance: state.user_guidance
      })

    system = "You are preparing skill input. Always respond with valid JSON only."

    case call_local_llm(prompt, system) do
      {:ok, raw_response} ->
        case PromptParser.parse_execution(raw_response) do
          {:ok, parsed} ->
            input_text = Map.get(parsed, "input", "")
            wm = Map.get(parsed, "working_memory", state.working_memory)
            timeout = state.config.step_timeout_ms

            skill_result =
              SkillExecutor.execute(
                skill_name,
                %{input: input_text},
                state.config.skill_whitelist,
                timeout: timeout
              )

            duration = System.monotonic_time(:millisecond) - started

            {:executing,
             {:ok, skill_name, input_text, skill_result, wm, prompt, raw_response, duration}}

          {:error, :parse_failed, reason} ->
            duration = System.monotonic_time(:millisecond) - started
            {:executing, {:error, reason, skill_name, prompt, raw_response, duration}}
        end

      {:error, reason} ->
        duration = System.monotonic_time(:millisecond) - started
        {:executing, {:error, inspect(reason), skill_name, prompt, nil, duration}}
    end
  end

  defp run_evaluation(state) do
    started = System.monotonic_time(:millisecond)

    latest = Reasoning.latest_step(state.session_id)

    prompt =
      Prompts.evaluation(%{
        goal: state.goal,
        step_description: latest && latest.skill_name || "unknown",
        skill_name: latest && latest.skill_name || "unknown",
        skill_output: latest && latest.skill_output || "(no output)",
        working_memory: state.working_memory
      })

    system = "You are evaluating a skill result. Always respond with valid JSON only."

    case call_local_llm(prompt, system) do
      {:ok, raw_response} ->
        duration = System.monotonic_time(:millisecond) - started

        case PromptParser.parse_evaluation(raw_response) do
          {:ok, parsed} ->
            {:evaluating, {:ok, parsed, prompt, raw_response, duration}}

          {:error, :parse_failed, reason} ->
            {:evaluating, {:error, reason, prompt, raw_response, duration}}
        end

      {:error, reason} ->
        duration = System.monotonic_time(:millisecond) - started
        {:evaluating, {:error, inspect(reason), prompt, nil, duration}}
    end
  end

  defp run_decision(state) do
    started = System.monotonic_time(:millisecond)

    completed = summarize_completed_steps(state)
    plan_summary = summarize_plan(state.plan)

    prompt =
      Prompts.decision(%{
        goal: state.goal,
        plan_summary: plan_summary,
        completed_steps: completed,
        iteration: state.iteration,
        max_iterations: state.config.max_iterations,
        consecutive_failures: state.consecutive_failures,
        working_memory: state.working_memory,
        user_guidance: state.user_guidance
      })

    system = "You are a decision-making assistant. Always respond with valid JSON only."

    case call_local_llm(prompt, system) do
      {:ok, raw_response} ->
        duration = System.monotonic_time(:millisecond) - started

        case PromptParser.parse_decision(raw_response) do
          {:ok, parsed} ->
            {:deciding, {:ok, parsed, prompt, raw_response, duration}}

          {:error, :parse_failed, reason} ->
            {:deciding, {:error, reason, prompt, raw_response, duration}}
        end

      {:error, reason} ->
        duration = System.monotonic_time(:millisecond) - started
        {:deciding, {:error, inspect(reason), prompt, nil, duration}}
    end
  end

  defp run_user_override(state, skill_name, input) do
    started = System.monotonic_time(:millisecond)
    timeout = state.config.step_timeout_ms

    result =
      SkillExecutor.execute(
        skill_name,
        %{input: input},
        state.config.skill_whitelist,
        timeout: timeout
      )

    duration = System.monotonic_time(:millisecond) - started
    {:user_override, {skill_name, input, result, duration}}
  end

  # --- Phase Result Handlers ---

  defp handle_phase_result(:planning, {:ok, parsed, prompt, raw, duration}, state) do
    steps = Map.get(parsed, "steps", [])
    wm = Map.get(parsed, "working_memory", state.working_memory)
    state = increment_llm_calls(state)

    Reasoning.record_step(%{
      session_id: state.session_id,
      iteration: state.iteration,
      phase: "plan",
      llm_prompt: prompt,
      llm_response: raw,
      working_memory_snapshot: wm,
      duration_ms: duration
    })

    case Map.get(parsed, "error") do
      nil ->
        Reasoning.update_session(state.session, %{plan: %{"steps" => steps}, working_memory: wm})
        state = %{state | plan: steps, working_memory: wm, current_step_index: 0}
        broadcast(:plan_ready, %{session_id: state.session_id, steps: steps})
        {:noreply, state, {:continue, :execute_step}}

      error_msg ->
        finish_session(state, :stuck, "Cannot achieve goal: #{error_msg}")
        {:stop, :normal, state}
    end
  end

  defp handle_phase_result(:planning, {:error, reason, prompt, raw, duration}, state) do
    state = if raw, do: increment_llm_calls(state), else: state

    record_error_step(state, reason, %{
      phase: "plan",
      llm_prompt: prompt,
      llm_response: raw,
      duration_ms: duration
    })

    state = %{state | consecutive_failures: state.consecutive_failures + 1}

    if state.consecutive_failures >= state.config.stuck_threshold do
      finish_session(state, :stuck, "Planning failed #{state.consecutive_failures} times: #{reason}")
      {:stop, :normal, state}
    else
      # Retry planning
      {:noreply, state, {:continue, :start_planning}}
    end
  end

  defp handle_phase_result(:executing, {:ok, skill_name, input, skill_result, wm, prompt, raw, duration}, state) do
    state = increment_llm_calls(state)
    {skill_output, error} = extract_skill_result(skill_result)

    action_hash = action_hash(skill_name, input)
    state = track_action(state, action_hash)

    Reasoning.record_step(%{
      session_id: state.session_id,
      iteration: state.iteration,
      phase: "execute",
      skill_name: skill_name,
      llm_prompt: prompt,
      llm_response: raw,
      skill_input: %{input: input},
      skill_output: skill_output,
      error: error,
      user_guidance: state.user_guidance,
      working_memory_snapshot: wm,
      duration_ms: duration
    })

    state = %{state | working_memory: wm, user_guidance: nil}

    case skill_result do
      {:ok, _} ->
        state = %{state | consecutive_failures: 0}
        {:noreply, state, {:continue, :evaluate}}

      {:error, _} ->
        state = %{state | consecutive_failures: state.consecutive_failures + 1}

        if state.consecutive_failures >= state.config.stuck_threshold do
          finish_session(state, :stuck, "#{state.consecutive_failures} consecutive skill failures")
          {:stop, :normal, state}
        else
          {:noreply, state, {:continue, :decide}}
        end
    end
  end

  defp handle_phase_result(:executing, {:error, reason, skill_name, prompt, raw, duration}, state) do
    state = if raw, do: increment_llm_calls(state), else: state

    record_error_step(state, reason, %{
      phase: "execute",
      skill_name: skill_name,
      llm_prompt: prompt,
      llm_response: raw,
      duration_ms: duration
    })

    state = %{state | consecutive_failures: state.consecutive_failures + 1}

    if state.consecutive_failures >= state.config.stuck_threshold do
      finish_session(state, :stuck, "Execution prep failed #{state.consecutive_failures} times")
      {:stop, :normal, state}
    else
      {:noreply, state, {:continue, :decide}}
    end
  end

  defp handle_phase_result(:evaluating, {:ok, parsed, prompt, raw, duration}, state) do
    state = increment_llm_calls(state)
    quality = Map.get(parsed, "quality", "failed")
    wm = Map.get(parsed, "working_memory", state.working_memory)

    rubric = Map.take(parsed, ["relevance", "completeness", "usability", "goal_progress"])

    Reasoning.record_step(%{
      session_id: state.session_id,
      iteration: state.iteration,
      phase: "evaluate",
      llm_prompt: prompt,
      llm_response: raw,
      rubric_scores: rubric,
      working_memory_snapshot: wm,
      duration_ms: duration
    })

    state = %{state | working_memory: wm}

    broadcast(:evaluation_done, %{
      session_id: state.session_id,
      quality: quality,
      rubric: rubric
    })

    if quality == "failed" do
      state = %{state | consecutive_failures: state.consecutive_failures + 1}
      {:noreply, state, {:continue, :decide}}
    else
      state = %{state | consecutive_failures: 0}
      {:noreply, state, {:continue, :decide}}
    end
  end

  defp handle_phase_result(:evaluating, {:error, reason, prompt, raw, duration}, state) do
    state = if raw, do: increment_llm_calls(state), else: state

    record_error_step(state, reason, %{
      phase: "evaluate",
      llm_prompt: prompt,
      llm_response: raw,
      duration_ms: duration
    })

    # Evaluation failure is not fatal — skip to decision
    {:noreply, state, {:continue, :decide}}
  end

  defp handle_phase_result(:deciding, {:ok, parsed, prompt, raw, duration}, state) do
    state = increment_llm_calls(state)
    action = Map.get(parsed, "action", "continue")
    confidence = parse_confidence(Map.get(parsed, "confidence"))
    wm = Map.get(parsed, "working_memory", state.working_memory)

    Reasoning.record_step(%{
      session_id: state.session_id,
      iteration: state.iteration,
      phase: "decide",
      decision: action,
      confidence: confidence,
      llm_prompt: prompt,
      llm_response: raw,
      working_memory_snapshot: wm,
      duration_ms: duration
    })

    state = %{state | working_memory: wm, user_guidance: nil}

    broadcast(:decision_made, %{
      session_id: state.session_id,
      action: action,
      confidence: confidence
    })

    handle_decision(action, parsed, confidence, state)
  end

  defp handle_phase_result(:deciding, {:error, reason, prompt, raw, duration}, state) do
    state = if raw, do: increment_llm_calls(state), else: state

    record_error_step(state, reason, %{
      phase: "decide",
      llm_prompt: prompt,
      llm_response: raw,
      duration_ms: duration
    })

    state = %{state | consecutive_failures: state.consecutive_failures + 1}

    if state.consecutive_failures >= state.config.stuck_threshold do
      finish_session(state, :stuck, "Decision failed #{state.consecutive_failures} times")
      {:stop, :normal, state}
    else
      # Retry decision
      {:noreply, state, {:continue, :decide}}
    end
  end

  defp handle_phase_result(:user_override, {skill_name, input, skill_result, duration}, state) do
    {skill_output, error} = extract_skill_result(skill_result)

    Reasoning.record_step(%{
      session_id: state.session_id,
      iteration: state.iteration,
      phase: "user_override",
      skill_name: skill_name,
      skill_input: %{input: input},
      skill_output: skill_output,
      error: error,
      working_memory_snapshot: state.working_memory,
      duration_ms: duration
    })

    case skill_result do
      {:ok, _} ->
        state = %{state | consecutive_failures: 0}
        {:noreply, state, {:continue, :evaluate}}

      {:error, _} ->
        state = %{state | consecutive_failures: state.consecutive_failures + 1}
        {:noreply, state, {:continue, :decide}}
    end
  end

  # --- Decision Routing ---

  defp handle_decision("done", parsed, confidence, state) do
    threshold = state.config.done_confidence_threshold

    if confidence >= threshold do
      result = Map.get(parsed, "final_answer", state.working_memory)
      deliver_result(state, result, confidence)
      finish_session(state, :completed, result, confidence)
      {:stop, :normal, state}
    else
      # Confidence too low — keep going
      Logger.info("[ReasoningLoop] Done declared with low confidence #{confidence} < #{threshold}")

      wm = "#{state.working_memory}\n[LOW CONFIDENCE] Previous attempt declared done with confidence #{confidence}, which is below threshold #{threshold}. Keep iterating to improve the answer."
      state = %{state | working_memory: wm, iteration: state.iteration + 1}
      Reasoning.increment_iteration(state.session)
      {:noreply, state, {:continue, :execute_step}}
    end
  end

  defp handle_decision("continue", _parsed, _confidence, state) do
    state = %{state | current_step_index: state.current_step_index + 1, iteration: state.iteration + 1}
    Reasoning.increment_iteration(state.session)
    {:noreply, state, {:continue, :execute_step}}
  end

  defp handle_decision("adjust", parsed, _confidence, state) do
    new_plan = Map.get(parsed, "new_plan", [])

    if is_list(new_plan) and length(new_plan) > 0 do
      Reasoning.update_session(state.session, %{plan: %{"steps" => new_plan}})
      state = %{state | plan: new_plan, current_step_index: 0, iteration: state.iteration + 1}
      Reasoning.increment_iteration(state.session)
      broadcast(:plan_adjusted, %{session_id: state.session_id, new_plan: new_plan})
      {:noreply, state, {:continue, :execute_step}}
    else
      # Invalid new plan — retry decision
      {:noreply, state, {:continue, :decide}}
    end
  end

  defp handle_decision("ask_user", parsed, _confidence, state) do
    question = Map.get(parsed, "question", "I need more information to proceed.")
    state = %{state | status: :waiting_user}
    update_session_status(state, "waiting_user")
    broadcast(:waiting_user, %{session_id: state.session_id, question: question})
    {:noreply, state}
  end

  defp handle_decision("stuck", _parsed, _confidence, state) do
    finish_session(state, :stuck, "Loop declared itself stuck")
    {:stop, :normal, state}
  end

  defp handle_decision(unknown, _parsed, _confidence, state) do
    Logger.warning("[ReasoningLoop] Unknown decision action: #{inspect(unknown)}, treating as continue")
    handle_decision("continue", %{}, nil, state)
  end

  # --- Helpers ---

  defp build_config(opts) do
    %{
      max_iterations: Keyword.get(opts, :max_iterations, config_int("reasoning.max_iterations", 15)),
      max_llm_calls: Keyword.get(opts, :max_llm_calls, config_int("reasoning.max_llm_calls", 60)),
      time_budget_ms: Keyword.get(opts, :time_budget_ms, config_int("reasoning.time_budget_seconds", 900) * 1000),
      skill_whitelist: Keyword.get(opts, :skill_whitelist, config_json("reasoning.skill_whitelist", [])),
      stuck_threshold: Keyword.get(opts, :stuck_threshold, config_int("reasoning.stuck_threshold", 3)),
      step_timeout_ms: Keyword.get(opts, :step_timeout_ms, config_int("reasoning.step_timeout_seconds", 120) * 1000),
      max_plan_steps: Keyword.get(opts, :max_plan_steps, config_int("reasoning.max_plan_steps", 8)),
      done_confidence_threshold: Keyword.get(opts, :done_confidence_threshold, config_float("reasoning.done_confidence_threshold", 0.7)),
      delivery: Keyword.get(opts, :delivery, config_json("reasoning.default_delivery", ["memory"]))
    }
  end

  defp create_session(goal, config) do
    Reasoning.create_session(%{
      goal: goal,
      status: "planning",
      config: config,
      delivery_config: %{channels: config.delivery},
      started_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end

  defp call_local_llm(prompt, system) do
    LLM.complete(prompt, tier: :local, system: system)
  end

  defp spawn_llm_task(fun) do
    Task.Supervisor.async_nolink(AlexClaw.TaskSupervisor, fun)
  end

  defp shutdown_task(%{task_ref: nil}), do: :ok

  defp shutdown_task(%{task_ref: ref}) do
    Process.demonitor(ref, [:flush])
    # The task is under TaskSupervisor, find and kill it
    :ok
  end

  defp check_limits(state) do
    cond do
      state.iteration > state.config.max_iterations -> {:exceeded, :max_iterations}
      state.total_llm_calls >= state.config.max_llm_calls -> {:exceeded, :max_llm_calls}
      is_duplicate_action?(state) -> {:exceeded, :duplicate_actions}
      true -> :ok
    end
  end

  defp handle_limit_exceeded(state) do
    {_, reason} = check_limits(state)
    Logger.warning("[ReasoningLoop] Limit exceeded: #{reason}")
    finish_session(state, :failed, "Limit exceeded: #{reason}")
    {:stop, :normal, state}
  end

  defp finish_session(state, :completed, result, confidence) do
    Reasoning.mark_completed(state.session, result, confidence)
    broadcast(:session_complete, %{session_id: state.session_id, status: :completed, result: result})
    cancel_timer(state)
  end

  defp finish_session(state, :aborted, reason) do
    Reasoning.mark_aborted(state.session)
    broadcast(:session_complete, %{session_id: state.session_id, status: :aborted, reason: reason})
    cancel_timer(state)
  end

  defp finish_session(state, :stuck, reason) do
    Reasoning.mark_stuck(state.session, reason)
    broadcast(:session_complete, %{session_id: state.session_id, status: :stuck, reason: reason})
    cancel_timer(state)
  end

  defp finish_session(state, :failed, reason) do
    Reasoning.mark_failed(state.session, reason)
    broadcast(:session_complete, %{session_id: state.session_id, status: :failed, reason: reason})
    cancel_timer(state)
  end

  defp deliver_result(state, result, confidence) do
    # Always store to memory
    Memory.store(:reasoning, result,
      source: "reasoning_loop",
      metadata: %{
        session_id: state.session_id,
        goal: state.goal,
        confidence: confidence,
        iterations: state.iteration
      }
    )

    # Delivery channels from config
    channels = state.config.delivery

    if "telegram" in channels do
      try do
        AlexClaw.Gateway.Telegram.send_message(
          "Reasoning loop complete (confidence: #{Float.round(confidence, 2)}):\n\n#{String.slice(result, 0, 3000)}"
        )
      rescue
        _ -> Logger.warning("[ReasoningLoop] Failed to deliver via Telegram")
      end
    end

    if "discord" in channels do
      try do
        AlexClaw.Gateway.Discord.send_message(
          "Reasoning loop complete (confidence: #{Float.round(confidence, 2)}):\n\n#{String.slice(result, 0, 1800)}"
        )
      rescue
        _ -> Logger.warning("[ReasoningLoop] Failed to deliver via Discord")
      end
    end
  end

  defp increment_llm_calls(state) do
    total = state.total_llm_calls + 1
    Reasoning.increment_llm_calls(state.session)
    %{state | total_llm_calls: total}
  end

  defp update_session_status(state, status) do
    Reasoning.update_session(state.session, %{status: status})
  end

  defp persist_working_memory(state) do
    Reasoning.update_session(state.session, %{working_memory: state.working_memory})
  end

  defp record_error_step(state, reason, extra \\ %{}) do
    base = %{
      session_id: state.session_id,
      iteration: state.iteration,
      phase: Map.get(extra, :phase, "execute"),
      error: reason,
      working_memory_snapshot: state.working_memory,
      duration_ms: Map.get(extra, :duration_ms, 0)
    }

    Reasoning.record_step(Map.merge(base, extra))
  end

  defp extract_skill_result({:ok, output}), do: {output, nil}
  defp extract_skill_result({:error, reason}), do: {nil, inspect(reason)}

  defp fetch_prior_knowledge(goal) do
    memories =
      case Memory.search(goal, limit: 5) do
        results when is_list(results) and results != [] ->
          results
          |> Enum.map_join("\n", fn entry ->
            content = if is_map(entry), do: Map.get(entry, :content, inspect(entry)), else: inspect(entry)
            "- #{String.slice(content, 0, 200)}"
          end)

        _ ->
          nil
      end

    knowledge =
      case Knowledge.search(goal, limit: 3) do
        results when is_list(results) and results != [] ->
          results
          |> Enum.map_join("\n", fn entry ->
            content = if is_map(entry), do: Map.get(entry, :content, inspect(entry)), else: inspect(entry)
            "- #{String.slice(content, 0, 200)}"
          end)

        _ ->
          nil
      end

    [memories && "From memory:\n#{memories}", knowledge && "From knowledge base:\n#{knowledge}"]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp summarize_previous_results(state) do
    state.session_id
    |> Reasoning.list_steps()
    |> Enum.filter(&(&1.phase == "execute" and &1.skill_output))
    |> Enum.map_join("\n", fn step ->
      output = String.slice(step.skill_output, 0, 300)
      "Step #{step.iteration} (#{step.skill_name}): #{output}"
    end)
    |> case do
      "" -> "None yet."
      text -> text
    end
  end

  defp summarize_completed_steps(state) do
    state.session_id
    |> Reasoning.list_steps()
    |> Enum.filter(&(&1.phase in ["execute", "user_override", "evaluate"]))
    |> Enum.map_join("\n", fn step ->
      status = if step.error, do: "FAILED", else: "OK"
      "Iteration #{step.iteration}: #{step.phase} #{step.skill_name || ""} [#{status}]"
    end)
    |> case do
      "" -> "None yet."
      text -> text
    end
  end

  defp summarize_plan(plan) do
    plan
    |> Enum.map_join("\n", fn step ->
      "#{step["step"]}. #{step["skill"]}: #{step["input_description"] || step["reason"] || ""}"
    end)
    |> case do
      "" -> "No plan yet."
      text -> text
    end
  end

  defp action_hash(skill_name, input) do
    :crypto.hash(:sha256, "#{skill_name}:#{input}")
  end

  defp track_action(state, hash) do
    recent = [hash | Enum.take(state.recent_actions, 9)]
    %{state | recent_actions: recent}
  end

  defp is_duplicate_action?(state) do
    case state.recent_actions do
      [a, b, c | _] when a == b and b == c -> true
      _ -> false
    end
  end

  defp resume_phase(%{status: :waiting_user}), do: :decide
  defp resume_phase(%{status: :paused}), do: :execute_step
  defp resume_phase(_), do: :execute_step

  defp parse_confidence(val) when is_float(val), do: val
  defp parse_confidence(val) when is_integer(val), do: val / 1.0

  defp parse_confidence(val) when is_binary(val) do
    case Float.parse(val) do
      {n, _} -> n
      :error -> 0.0
    end
  end

  defp parse_confidence(_), do: 0.0

  defp cancel_timer(%{time_budget_ref: ref}) when is_reference(ref) do
    Process.cancel_timer(ref)
  end

  defp cancel_timer(_), do: :ok

  defp broadcast(event, data) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {event, data})
  end

  defp phase_data(state, phase, extra \\ %{}) do
    Map.merge(
      %{
        session_id: state.session_id,
        iteration: state.iteration,
        phase: phase,
        status: state.status
      },
      extra
    )
  end

  defp config_int(key, default) do
    case Config.get(key) do
      val when is_integer(val) -> val
      val when is_binary(val) ->
        case Integer.parse(val) do
          {n, _} -> n
          :error -> default
        end
      _ -> default
    end
  end

  defp config_float(key, default) do
    case Config.get(key) do
      val when is_float(val) -> val
      val when is_integer(val) -> val / 1.0
      val when is_binary(val) ->
        case Float.parse(val) do
          {n, _} -> n
          :error -> default
        end
      _ -> default
    end
  end

  defp config_json(key, default) do
    case Config.get(key) do
      val when is_list(val) -> val
      val when is_binary(val) ->
        case Jason.decode(val) do
          {:ok, decoded} -> decoded
          _ -> default
        end
      _ -> default
    end
  end

end
