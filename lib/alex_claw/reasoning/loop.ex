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

        # Initial timer covers planning phase only (2 min generous)
        time_budget_ref =
          Process.send_after(self(), :time_budget_exceeded, 120_000)

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

      cond do
        is_nil(step) ->
          # No more steps — go to decision
          {:noreply, state, {:continue, :decide}}

        is_nil(step["skill"]) or step["skill"] == "" ->
          # Malformed step — skip and log
          Logger.warning("[ReasoningLoop] Skipping step with nil/empty skill: #{inspect(step)}")
          record_error_step(state, "Step has no skill name: #{inspect(step)}", %{phase: "execute"})
          state = %{state | current_step_index: state.current_step_index + 1}
          {:noreply, state, {:continue, :execute_step}}

        true ->
          broadcast(:phase_change, phase_data(state, :executing, %{skill: step["skill"]}))
          task = spawn_llm_task(fn -> run_execution(state, step) end)
          {:noreply, %{state | task_ref: task.ref}}
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

  def handle_continue(:maybe_compress, state) do
    if rem(state.iteration, 3) == 0 and byte_size(state.working_memory || "") > 500 do
      Logger.info("[ReasoningLoop] Compressing working memory at iteration #{state.iteration}")
      task = spawn_llm_task(fn -> run_compression(state) end)
      {:noreply, %{state | task_ref: task.ref}}
    else
      {:noreply, state, {:continue, :decide}}
    end
  end

  def handle_continue(:decide, state) do
    # Deterministic pre-filter: handle obvious decisions without LLM call
    case deterministic_decision(state) do
      {:decided, action, reason} ->
        Logger.info("[ReasoningLoop] Deterministic decision: #{action} — #{reason}")

        Reasoning.record_step(%{
          session_id: state.session_id,
          iteration: state.iteration,
          phase: "decide",
          decision: to_string(action),
          working_memory_snapshot: state.working_memory,
          duration_ms: 0
        })

        broadcast(:phase_change, phase_data(state, :deciding))

        case action do
          :force_summary ->
            # All steps done — produce final answer via LLM
            task = spawn_llm_task(fn -> run_forced_summary(state) end)
            {:noreply, %{state | task_ref: task.ref}}

          _ ->
            handle_decision(to_string(action), %{}, 0.0, state)
        end

      :ambiguous ->
        # Genuinely ambiguous — ask the LLM
        state = %{state | status: :deciding}
        update_session_status(state, "deciding")
        broadcast(:phase_change, phase_data(state, :deciding))

        task = spawn_llm_task(fn -> run_decision(state) end)
        {:noreply, %{state | task_ref: task.ref}}
    end
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

  @impl true
  def terminate(reason, state) do
    cancel_timer(state)

    # Only mark as failed if the session isn't already in a terminal state
    case state.session && state.session.status do
      status when status in ["completed", "failed", "aborted", "stuck"] ->
        :ok

      _ ->
        Logger.warning("[ReasoningLoop] Process terminating: #{inspect(reason)}")
        Reasoning.mark_failed(state.session, "Process terminated: #{inspect(reason)}")
    end

    :ok
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

    case call_llm(prompt, system, state) do
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

    case call_llm(prompt, system, state) do
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

    case call_llm(prompt, system, state) do
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

    score_trend = calculate_score_trend(state)

    prompt =
      Prompts.decision(%{
        goal: state.goal,
        plan_summary: plan_summary,
        completed_steps: completed,
        iteration: state.iteration,
        max_iterations: state.config.max_iterations,
        consecutive_failures: state.consecutive_failures,
        working_memory: state.working_memory,
        user_guidance: state.user_guidance,
        score_trend: score_trend
      })

    system = "You are a decision-making assistant. Always respond with valid JSON only."

    case call_llm(prompt, system, state) do
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

  defp run_compression(state) do
    started = System.monotonic_time(:millisecond)

    prompt = """
    You are compressing a working memory string. Keep ONLY essential facts, decisions, and results.
    Discard process notes, redundant observations, and stale information.

    Goal: #{state.goal}
    Current iteration: #{state.iteration}

    Working memory to compress:
    #{state.working_memory}

    Respond with ONLY valid JSON:
    {"compressed": "the compressed essential facts only"}
    """

    system = "You are a context compressor. Respond with valid JSON only."

    case call_llm(prompt, system, state) do
      {:ok, raw} ->
        duration = System.monotonic_time(:millisecond) - started
        {:compression, {:ok, raw, duration}}

      {:error, reason} ->
        duration = System.monotonic_time(:millisecond) - started
        {:compression, {:error, inspect(reason), duration}}
    end
  end

  defp run_forced_summary(state) do
    started = System.monotonic_time(:millisecond)

    completed = summarize_completed_steps(state)

    prompt = """
    You have been working on a goal and gathered information. Now produce the FINAL ANSWER.

    Goal: #{state.goal}

    Work completed:
    #{completed}

    Your accumulated understanding:
    #{state.working_memory}

    Write a clear, complete answer to the goal based on everything you have gathered.
    Do NOT say what you still need to do. Do NOT describe your process.
    Just answer the goal directly.

    Respond with ONLY valid JSON:
    {"answer": "your complete final answer here", "working_memory": "final summary"}
    """

    system = "You are producing a final answer. Respond with valid JSON only."

    case call_llm(prompt, system, state) do
      {:ok, raw_response} ->
        duration = System.monotonic_time(:millisecond) - started
        {:forced_summary, {:ok, raw_response, prompt, duration}}

      {:error, reason} ->
        duration = System.monotonic_time(:millisecond) - started
        {:forced_summary, {:error, inspect(reason), prompt, duration}}
    end
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

    cond do
      Map.get(parsed, "error") ->
        finish_session(state, :stuck, "Cannot achieve goal: #{parsed["error"]}")
        {:stop, :normal, state}

      steps == [] ->
        finish_session(state, :stuck, "Plan has no steps")
        {:stop, :normal, state}

      true ->
        case validate_plan(steps, state.config.skill_whitelist) do
          {:ok, valid_steps} ->
            Reasoning.update_session(state.session, %{plan: %{"steps" => valid_steps}, working_memory: wm})
            state = %{state | plan: valid_steps, working_memory: wm, current_step_index: 0}
            state = reset_time_budget(state, length(valid_steps))
            broadcast(:plan_ready, %{session_id: state.session_id, steps: valid_steps})
            {:noreply, state, {:continue, :execute_step}}

          {:error, errors} ->
            Logger.warning("[ReasoningLoop] Plan validation failed: #{errors}")
            # Inject validation errors into working memory and retry planning
            wm_with_errors = "#{wm}\n[PLAN VALIDATION FAILED] #{errors}. Fix these issues in the next plan."
            state = %{state | working_memory: wm_with_errors, consecutive_failures: state.consecutive_failures + 1}

            if state.consecutive_failures >= state.config.stuck_threshold do
              finish_session(state, :stuck, "Planning repeatedly failed validation: #{errors}")
              {:stop, :normal, state}
            else
              {:noreply, state, {:continue, :start_planning}}
            end
        end
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
        embed_skill_output(state, skill_name, skill_output)
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

    rubric =
      parsed
      |> Map.take(["relevance", "completeness", "usability", "goal_progress"])
      |> Map.put("quality", quality)

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
      {:noreply, state, {:continue, :maybe_compress}}
    else
      state = %{state | consecutive_failures: 0}
      {:noreply, state, {:continue, :maybe_compress}}
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

  defp handle_phase_result(:compression, {:ok, raw, duration}, state) do
    state = increment_llm_calls(state)

    compressed =
      case PromptParser.extract_answer(raw) do
        {:ok, text} -> text
        :fallback ->
          # Try extracting "compressed" key
          case Jason.decode(raw) do
            {:ok, %{"compressed" => text}} -> text
            _ -> state.working_memory
          end
      end

    Logger.info("[ReasoningLoop] Working memory compressed: #{byte_size(state.working_memory)} → #{byte_size(compressed)} bytes")
    state = %{state | working_memory: compressed}
    persist_working_memory(state)
    {:noreply, state, {:continue, :decide}}
  end

  defp handle_phase_result(:compression, {:error, _reason, _duration}, state) do
    # Compression failed — proceed with uncompressed memory
    {:noreply, state, {:continue, :decide}}
  end

  defp handle_phase_result(:forced_summary, {:ok, raw, prompt, duration}, state) do
    state = increment_llm_calls(state)

    Reasoning.record_step(%{
      session_id: state.session_id,
      iteration: state.iteration,
      phase: "decide",
      decision: "done",
      llm_prompt: prompt,
      llm_response: raw,
      working_memory_snapshot: state.working_memory,
      duration_ms: duration
    })

    # Try to parse the answer, fall back to raw response
    result =
      case PromptParser.extract_answer(raw) do
        {:ok, answer} -> answer
        :fallback -> raw
      end

    confidence = state.config.done_confidence_threshold
    deliver_result(state, result, confidence)
    finish_session(state, :completed, result, confidence)
    {:stop, :normal, state}
  end

  defp handle_phase_result(:forced_summary, {:error, reason, prompt, duration}, state) do
    # Even the summary failed — deliver working memory as last resort
    record_error_step(state, reason, %{phase: "decide", llm_prompt: prompt, duration_ms: duration})
    result = state.working_memory
    confidence = state.config.done_confidence_threshold
    deliver_result(state, result, confidence)
    finish_session(state, :completed, result, confidence)
    {:stop, :normal, state}
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

  defp handle_decision("adjust", parsed, confidence, state) do
    threshold = state.config.done_confidence_threshold

    # Detect adjust oscillation: if confidence >= done threshold and we've adjusted before,
    # the model is polishing endlessly — treat as done
    prev_adjusts = count_recent_adjusts(state)

    if prev_adjusts >= 2 and confidence >= threshold do
      Logger.info("[ReasoningLoop] Adjust oscillation detected (#{prev_adjusts + 1} adjusts, confidence #{confidence}). Forcing final summary.")
      task = spawn_llm_task(fn -> run_forced_summary(state) end)
      {:noreply, %{state | task_ref: task.ref}}
    else
      new_plan = Map.get(parsed, "new_plan", [])

      cond do
        !is_list(new_plan) or new_plan == [] ->
          # Invalid new plan — retry decision
          {:noreply, state, {:continue, :decide}}

        true ->
          case validate_plan(new_plan, state.config.skill_whitelist) do
            {:ok, valid_steps} ->
              Reasoning.update_session(state.session, %{plan: %{"steps" => valid_steps}})
              state = %{state | plan: valid_steps, current_step_index: 0, iteration: state.iteration + 1}
              state = reset_time_budget(state, length(valid_steps))
              Reasoning.increment_iteration(state.session)
              broadcast(:plan_adjusted, %{session_id: state.session_id, new_plan: valid_steps})
              {:noreply, state, {:continue, :execute_step}}

            {:error, _errors} ->
              # Bad adjusted plan — retry decision instead of executing garbage
              {:noreply, state, {:continue, :decide}}
          end
      end
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
      delivery: Keyword.get(opts, :delivery, config_json("reasoning.default_delivery", ["memory"])),
      llm_tier: Keyword.get(opts, :llm_tier, config_atom("reasoning.llm_tier", :local))
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

  defp call_llm(prompt, system, state) do
    tier = state.config.llm_tier
    LLM.complete(prompt, tier: tier, system: system)
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

  defp embed_skill_output(_state, _skill_name, nil), do: :ok
  defp embed_skill_output(_state, _skill_name, ""), do: :ok

  defp embed_skill_output(state, skill_name, output) do
    Memory.store(:reasoning, output,
      source: "reasoning_loop",
      metadata: %{
        session_id: state.session_id,
        goal: state.goal,
        iteration: state.iteration,
        skill: skill_name
      }
    )
  end

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

  defp deterministic_decision(state) do
    # current_step_index points at the step that just executed (0-based)
    # "last step" means the next index would be past the plan
    on_last_step = state.current_step_index >= length(state.plan) - 1
    last_eval_good = last_evaluation_quality(state) == "good"

    cond do
      # Consecutive failures at threshold → stuck (check first, highest priority)
      state.consecutive_failures >= state.config.stuck_threshold ->
        {:decided, :stuck, "#{state.consecutive_failures} consecutive failures"}

      # Last plan step executed and eval was good → produce final answer
      on_last_step and last_eval_good and state.consecutive_failures == 0 ->
        {:decided, :force_summary, "all plan steps completed with good evaluation"}

      # Last plan step done but eval was bad → need LLM to decide (adjust or retry)
      on_last_step and not last_eval_good ->
        :ambiguous

      # Still have plan steps remaining and no failures → continue
      not on_last_step and state.consecutive_failures == 0 ->
        {:decided, :continue, "plan step #{state.current_step_index + 2} of #{length(state.plan)} remaining"}

      # Everything else is genuinely ambiguous
      true ->
        :ambiguous
    end
  end

  defp calculate_score_trend(state) do
    scores =
      state.session_id
      |> Reasoning.list_steps()
      |> Enum.filter(&(&1.phase == "evaluate" and &1.rubric_scores))
      |> Enum.take(-3)
      |> Enum.map(fn step ->
        rubric = step.rubric_scores
        vals =
          ["relevance", "completeness", "usability", "goal_progress"]
          |> Enum.map(fn k ->
            case Map.get(rubric, k) do
              v when is_number(v) -> v
              _ -> nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        if vals == [], do: nil, else: Enum.sum(vals) / length(vals)
      end)
      |> Enum.reject(&is_nil/1)

    case scores do
      [] -> nil
      [_single] -> %{scores: scores, trend: 0.0}
      _ ->
        # Simple trend: average difference between consecutive scores
        diffs =
          scores
          |> Enum.chunk_every(2, 1, :discard)
          |> Enum.map(fn [a, b] -> b - a end)

        trend = Enum.sum(diffs) / length(diffs)
        %{scores: scores, trend: trend}
    end
  end

  defp last_evaluation_quality(state) do
    state.session_id
    |> Reasoning.list_steps()
    |> Enum.filter(&(&1.phase == "evaluate" and &1.rubric_scores))
    |> List.last()
    |> case do
      nil -> nil
      step ->
        rubric = step.rubric_scores

        # Check explicit quality first, then compute from scores
        case Map.get(rubric, "quality") do
          q when q in ["good", "partial", "failed"] -> q
          _ -> compute_quality_from_scores(rubric)
        end
    end
  end

  defp compute_quality_from_scores(rubric) do
    scores =
      ["relevance", "completeness", "usability", "goal_progress"]
      |> Enum.map(fn k ->
        case Map.get(rubric, k) do
          v when is_number(v) -> v
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    case scores do
      [] -> nil
      vals ->
        avg = Enum.sum(vals) / length(vals)
        cond do
          avg >= 3.5 -> "good"
          avg >= 2.0 -> "partial"
          true -> "failed"
        end
    end
  end

  defp validate_plan(steps, whitelist) do
    {valid, errors} =
      Enum.reduce(steps, {[], []}, fn step, {valid_acc, err_acc} ->
        skill = step["skill"]

        cond do
          is_nil(skill) or skill == "" ->
            {valid_acc, ["Step #{step["step"]}: missing skill name" | err_acc]}

          skill not in whitelist ->
            {valid_acc, ["Step #{step["step"]}: skill '#{skill}' not in whitelist" | err_acc]}

          true ->
            {[step | valid_acc], err_acc}
        end
      end)

    case errors do
      [] -> {:ok, Enum.reverse(valid)}
      errs -> {:error, Enum.reverse(errs) |> Enum.join("; ")}
    end
  end

  defp count_recent_adjusts(state) do
    state.session_id
    |> Reasoning.list_steps()
    |> Enum.count(fn step -> step.phase == "decide" and step.decision == "adjust" end)
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

  # ~150s per step (execute ~90s + evaluate ~50s + overhead) + 60s buffer for final summary
  @seconds_per_step 150

  defp reset_time_budget(state, step_count) do
    cancel_timer(state)
    budget_ms = step_count * @seconds_per_step * 1000 + 60_000
    Logger.info("[ReasoningLoop] Time budget set to #{div(budget_ms, 1000)}s for #{step_count} steps")
    ref = Process.send_after(self(), :time_budget_exceeded, budget_ms)
    %{state | time_budget_ref: ref}
  end

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

  defp config_atom(key, default) do
    case Config.get(key) do
      val when is_atom(val) -> val
      val when is_binary(val) and val != "" -> String.to_existing_atom(val)
      _ -> default
    end
  rescue
    ArgumentError -> default
  end

end
