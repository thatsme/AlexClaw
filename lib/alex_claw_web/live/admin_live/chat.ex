defmodule AlexClawWeb.AdminLive.Chat do
  @moduledoc "Interactive chat with LLM provider selection and reasoning loop mode."

  use Phoenix.LiveView

  alias AlexClaw.{Config, Identity, LLM, Memory}
  alias AlexClaw.Reasoning
  alias AlexClaw.Reasoning.Loop

  @reasoning_topic "reasoning:loop"

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(AlexClaw.PubSub, @reasoning_topic)
    end

    # Check for active reasoning session
    {mode, reasoning_assigns} = load_reasoning_state()

    {:ok,
     socket
     |> assign(
       page_title: "Chat",
       messages: [],
       loading: false,
       provider: "auto",
       providers: LLM.list_provider_choices(),
       mode: mode
     )
     |> assign(reasoning_assigns)}
  end

  # --- Chat Mode Events ---

  @impl true
  def handle_event("send", %{"message" => message}, %{assigns: %{mode: :chat}} = socket) do
    message = String.trim(message)

    if message == "" do
      {:noreply, socket}
    else
      user_msg = %{role: :user, content: message, timestamp: DateTime.utc_now()}
      messages = socket.assigns.messages ++ [user_msg]
      provider = socket.assigns.provider

      socket =
        socket
        |> assign(messages: messages, loading: true)
        |> start_async(:llm_response, fn -> generate_response(message, provider) end)

      {:noreply, socket}
    end
  end

  def handle_event("set_provider", %{"provider" => provider}, socket) do
    {:noreply, assign(socket, provider: provider)}
  end

  def handle_event("clear", _params, socket) do
    {:noreply, assign(socket, messages: [])}
  end

  # --- Mode Toggle ---

  def handle_event("toggle_mode", _params, socket) do
    new_mode = if socket.assigns.mode == :chat, do: :reasoning, else: :chat
    {:noreply, assign(socket, mode: new_mode)}
  end

  # --- Reasoning Mode Events ---

  def handle_event("start_reasoning", %{"goal" => goal}, socket) do
    goal = String.trim(goal)

    if goal == "" do
      {:noreply, socket}
    else
      enabled = Config.get("reasoning.enabled", true)

      if enabled do
        case Loop.start(goal) do
          {:ok, pid} ->
            {:noreply,
             assign(socket,
               loop_pid: pid,
               loop_status: :planning,
               reasoning_goal: goal,
               reasoning_steps: [],
               reasoning_plan: [],
               reasoning_result: nil,
               reasoning_error: nil,
               waiting_question: nil
             )}

          {:error, :session_already_active} ->
            {:noreply, put_flash(socket, :error, "A reasoning session is already active.")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to start: #{inspect(reason)}")}
        end
      else
        {:noreply, put_flash(socket, :error, "Reasoning loop is disabled in config.")}
      end
    end
  end

  def handle_event("pause_loop", _params, socket) do
    if socket.assigns.loop_pid, do: Loop.pause(socket.assigns.loop_pid)
    {:noreply, socket}
  end

  def handle_event("resume_loop", _params, socket) do
    if socket.assigns.loop_pid, do: Loop.resume(socket.assigns.loop_pid)
    {:noreply, socket}
  end

  def handle_event("abort_loop", _params, socket) do
    if socket.assigns.loop_pid, do: Loop.abort(socket.assigns.loop_pid)
    {:noreply, assign(socket, loop_status: :aborted, loop_pid: nil)}
  end

  def handle_event("steer", %{"guidance" => guidance}, socket) do
    guidance = String.trim(guidance)

    if guidance != "" and socket.assigns.loop_pid do
      Loop.steer(socket.assigns.loop_pid, guidance)
    end

    {:noreply, socket}
  end

  def handle_event("respond_to_loop", %{"response" => response}, socket) do
    response = String.trim(response)

    if response != "" and socket.assigns.loop_pid do
      Loop.add_context(socket.assigns.loop_pid, response)
      Loop.resume(socket.assigns.loop_pid)
      {:noreply, assign(socket, waiting_question: nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("override_step", %{"skill" => skill, "input" => input}, socket) do
    skill = String.trim(skill)
    input = String.trim(input)

    if skill != "" and input != "" and socket.assigns.loop_pid do
      Loop.override_step(socket.assigns.loop_pid, skill, input)
    end

    {:noreply, socket}
  end

  def handle_event("send", %{"message" => message}, %{assigns: %{mode: :reasoning}} = socket) do
    # In reasoning mode, the send form starts a new session or sends guidance
    if socket.assigns.loop_pid do
      # Session active — treat as steer
      handle_event("steer", %{"guidance" => message}, socket)
    else
      # No active session — start reasoning
      handle_event("start_reasoning", %{"goal" => message}, socket)
    end
  end

  def handle_event("view_session", %{"id" => id}, socket) do
    case Reasoning.get_session(String.to_integer(id)) do
      {:ok, session} ->
        steps = Reasoning.list_steps(session.id)

        {:noreply,
         assign(socket,
           mode: :reasoning,
           loop_pid: nil,
           loop_status: String.to_existing_atom(session.status),
           reasoning_goal: session.goal,
           reasoning_steps: format_steps(steps),
           reasoning_plan: get_plan_steps(session),
           reasoning_result: session.result,
           reasoning_error: session.error
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Session not found.")}
    end
  end

  # --- Chat Async Handlers ---

  @impl true
  def handle_async(:llm_response, {:ok, {:error, reason}}, socket) do
    error_msg = %{role: :system, content: "Error: #{inspect(reason)}", timestamp: DateTime.utc_now()}
    {:noreply, assign(socket, messages: socket.assigns.messages ++ [error_msg], loading: false)}
  end

  def handle_async(:llm_response, {:ok, response}, socket) when is_binary(response) do
    ai_msg = %{role: :assistant, content: response, timestamp: DateTime.utc_now()}
    messages = socket.assigns.messages ++ [ai_msg]

    user_msg = List.last(Enum.filter(socket.assigns.messages, &(&1.role == :user)))

    if user_msg do
      Memory.store(:conversation, "User: #{user_msg.content}", source: "web_chat")
      Memory.store(:conversation, "AlexClaw: #{response}", source: "web_chat")
    end

    {:noreply, assign(socket, messages: messages, loading: false)}
  end

  def handle_async(:llm_response, {:exit, reason}, socket) do
    error_msg = %{role: :system, content: "Request failed: #{inspect(reason)}", timestamp: DateTime.utc_now()}
    {:noreply, assign(socket, messages: socket.assigns.messages ++ [error_msg], loading: false)}
  end

  # --- PubSub Handlers (Reasoning Loop) ---

  @impl true
  def handle_info({:session_started, %{session_id: _id, goal: _goal}}, socket) do
    {:noreply, assign(socket, loop_status: :planning)}
  end

  def handle_info({:phase_change, %{phase: phase, session_id: session_id}}, socket) do
    steps = reload_steps(session_id)
    session = reload_session(session_id)
    plan = get_plan_steps(session)
    {:noreply, assign(socket, loop_status: phase, reasoning_steps: steps, reasoning_plan: plan)}
  end

  def handle_info({:plan_ready, %{session_id: session_id}}, socket) do
    session = reload_session(session_id)
    {:noreply, assign(socket, reasoning_plan: get_plan_steps(session))}
  end

  def handle_info({:plan_adjusted, %{session_id: session_id}}, socket) do
    session = reload_session(session_id)
    {:noreply, assign(socket, reasoning_plan: get_plan_steps(session))}
  end

  def handle_info({:evaluation_done, %{session_id: session_id}}, socket) do
    steps = reload_steps(session_id)
    {:noreply, assign(socket, reasoning_steps: steps)}
  end

  def handle_info({:decision_made, %{session_id: session_id, action: action, confidence: confidence}}, socket) do
    steps = reload_steps(session_id)
    {:noreply, assign(socket, reasoning_steps: steps, loop_status: :deciding)}
  end

  def handle_info({:waiting_user, %{question: question}}, socket) do
    {:noreply, assign(socket, loop_status: :waiting_user, waiting_question: question)}
  end

  def handle_info({:user_steer, _data}, socket) do
    {:noreply, socket}
  end

  def handle_info({:context_added, _data}, socket) do
    {:noreply, socket}
  end

  def handle_info({:session_complete, %{status: status} = data}, socket) do
    result = data[:result]
    reason = data[:reason]

    {:noreply,
     assign(socket,
       loop_status: status,
       loop_pid: nil,
       reasoning_result: result,
       reasoning_error: reason
     )}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # --- Private ---

  defp generate_response(query, provider) do
    system = Identity.system_prompt(%{skill: :conversational})

    recent =
      case Memory.recent(kind: :conversation, limit: 6) do
        [] ->
          ""

        entries ->
          history =
            entries
            |> Enum.reverse()
            |> Enum.map_join("\n", & &1.content)

          "\n\nRecent conversation:\n#{history}"
      end

    prompt = "#{recent}\n\nUser: #{query}"

    opts =
      case provider do
        "auto" -> [tier: :light]
        name -> [provider: name]
      end

    case LLM.complete(prompt, opts ++ [system: system]) do
      {:ok, response} -> response
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_reasoning_state do
    case Reasoning.active_session() do
      nil ->
        {:chat, default_reasoning_assigns()}

      session ->
        steps = Reasoning.list_steps(session.id)
        pid = find_loop_pid(session)

        {:reasoning,
         %{
           loop_pid: pid,
           loop_status: String.to_existing_atom(session.status),
           reasoning_goal: session.goal,
           reasoning_steps: format_steps(steps),
           reasoning_plan: get_plan_steps(session),
           reasoning_result: session.result,
           reasoning_error: session.error,
           waiting_question: nil
         }}
    end
  end

  defp default_reasoning_assigns do
    %{
      loop_pid: nil,
      loop_status: nil,
      reasoning_goal: nil,
      reasoning_steps: [],
      reasoning_plan: [],
      reasoning_result: nil,
      reasoning_error: nil,
      waiting_question: nil
    }
  end

  defp reload_steps(session_id) do
    session_id
    |> Reasoning.list_steps()
    |> format_steps()
  end

  defp reload_session(session_id) do
    case Reasoning.get_session(session_id) do
      {:ok, session} -> session
      _ -> nil
    end
  end

  defp find_loop_pid(session) do
    case :global.whereis_name({Loop, session.goal}) do
      :undefined -> nil
      pid -> pid
    end
  end

  defp format_steps(steps) do
    Enum.map(steps, fn step ->
      %{
        phase: step.phase,
        iteration: step.iteration,
        skill: step.skill_name,
        decision: step.decision,
        confidence: step.confidence,
        quality: step.rubric_scores && Map.get(step.rubric_scores, "quality"),
        rubric: step.rubric_scores,
        error: step.error,
        duration_ms: step.duration_ms,
        timestamp: step.inserted_at
      }
    end)
  end

  defp get_plan_steps(%{plan: %{"steps" => steps}}) when is_list(steps), do: steps
  defp get_plan_steps(_), do: []

  # --- Template Helpers ---

  defp status_color(:planning), do: "bg-blue-900/50 text-blue-400 border border-blue-800"
  defp status_color(:executing), do: "bg-claw-900/50 text-claw-400 border border-claw-800"
  defp status_color(:evaluating), do: "bg-purple-900/50 text-purple-400 border border-purple-800"
  defp status_color(:deciding), do: "bg-indigo-900/50 text-indigo-400 border border-indigo-800"
  defp status_color(:paused), do: "bg-yellow-900/50 text-yellow-400 border border-yellow-800"
  defp status_color(:waiting_user), do: "bg-amber-900/50 text-amber-400 border border-amber-800"
  defp status_color(:completed), do: "bg-green-900/50 text-green-400 border border-green-800"
  defp status_color(:failed), do: "bg-red-900/50 text-red-400 border border-red-800"
  defp status_color(:aborted), do: "bg-gray-800 text-gray-400 border border-gray-700"
  defp status_color(:stuck), do: "bg-orange-900/50 text-orange-400 border border-orange-800"
  defp status_color(_), do: "bg-gray-800 text-gray-400 border border-gray-700"

  defp status_label(:planning), do: "Planning"
  defp status_label(:executing), do: "Executing"
  defp status_label(:evaluating), do: "Evaluating"
  defp status_label(:deciding), do: "Deciding"
  defp status_label(:paused), do: "Paused"
  defp status_label(:waiting_user), do: "Waiting for input"
  defp status_label(:completed), do: "Completed"
  defp status_label(:failed), do: "Failed"
  defp status_label(:aborted), do: "Aborted"
  defp status_label(:stuck), do: "Stuck"
  defp status_label(_), do: "Unknown"

  defp step_dot_color(%{phase: "plan"}), do: "bg-blue-500"
  defp step_dot_color(%{phase: "execute"}), do: "bg-claw-500"
  defp step_dot_color(%{phase: "evaluate"}), do: "bg-purple-500"
  defp step_dot_color(%{phase: "decide"}), do: "bg-indigo-500"
  defp step_dot_color(%{phase: "user_override"}), do: "bg-amber-500"
  defp step_dot_color(%{phase: :evaluation_result}), do: "bg-purple-400"
  defp step_dot_color(%{phase: :decision_result}), do: "bg-indigo-400"
  defp step_dot_color(%{phase: :in_progress}), do: "bg-gray-500"
  defp step_dot_color(_), do: "bg-gray-600"

  defp step_phase_color(%{phase: "plan"}), do: "text-blue-400"
  defp step_phase_color(%{phase: "execute"}), do: "text-claw-400"
  defp step_phase_color(%{phase: "evaluate"}), do: "text-purple-400"
  defp step_phase_color(%{phase: "decide"}), do: "text-indigo-400"
  defp step_phase_color(%{phase: "user_override"}), do: "text-amber-400"
  defp step_phase_color(%{phase: :evaluation_result}), do: "text-purple-300"
  defp step_phase_color(%{phase: :decision_result}), do: "text-indigo-300"
  defp step_phase_color(_), do: "text-gray-400"

  defp step_label(%{phase: "plan"}), do: "PLAN"
  defp step_label(%{phase: "execute"}), do: "EXEC"
  defp step_label(%{phase: "evaluate"}), do: "EVAL"
  defp step_label(%{phase: "decide"}), do: "DECIDE"
  defp step_label(%{phase: "user_override"}), do: "OVERRIDE"
  defp step_label(%{phase: :evaluation_result, quality: q}), do: "EVAL: #{q}"
  defp step_label(%{phase: :decision_result, action: a}), do: "DECIDE: #{a}"
  defp step_label(%{phase: :in_progress}), do: "..."
  defp step_label(%{phase: phase}), do: to_string(phase)

  defp quality_color("good"), do: "text-green-400"
  defp quality_color("partial"), do: "text-yellow-400"
  defp quality_color("failed"), do: "text-red-400"
  defp quality_color(_), do: "text-gray-400"

  defp active_label(:planning), do: "Planning..."
  defp active_label(:executing), do: "Executing skill..."
  defp active_label(:evaluating), do: "Evaluating result..."
  defp active_label(:deciding), do: "Deciding next action..."
  defp active_label(_), do: "Working..."

  defp format_duration(nil), do: ""
  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms), do: "#{Float.round(ms / 1000, 1)}s"

  defp input_placeholder(nil, _), do: "Enter a goal to start reasoning..."
  defp input_placeholder(_pid, :paused), do: "Session paused. Resume or add guidance..."
  defp input_placeholder(_pid, _), do: "Send guidance to the running loop..."

  defp input_button_label(nil), do: "Start"
  defp input_button_label(_), do: "Guide"
end
