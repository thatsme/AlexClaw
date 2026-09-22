defmodule AlexClawWeb.AdminLive.Forge do
  @moduledoc "Interactive skill generation with real-time feedback. Uses RAG context from the knowledge base."

  use Phoenix.LiveView

  alias AlexClaw.LLM
  alias AlexClaw.Memory
  alias AlexClaw.Skills.{CodeGenerator, ForgeGuard}
  alias AlexClawWeb.Live.{ActionCode, Elevation}

  @default_max_retries 5

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, session, socket) do
    socket =
      socket
      |> Elevation.assign_elevation(session)
      |> ActionCode.assign_action_code()

    {:ok,
     assign(socket,
       page_title: "Forge",
       messages: [],
       code: nil,
       status: :idle,
       provider: "LM Studio",
       providers: LLM.list_provider_choices(),
       context_source: "docs",
       auto_iterate: true,
       max_retries: @default_max_retries,
       retries_left: @default_max_retries,
       loaded_skill: nil,
       error: nil,
       loading: false,
       current_goal: nil,
       current_skill_name: nil,
       last_failure: nil,
       deadline: nil
     )}
  end

  @impl true
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("send", %{"goal" => goal}, socket) do
    goal = String.trim(goal)

    if goal == "" do
      {:noreply, socket}
    else
      {:noreply, begin_generation(socket, ForgeGuard.acquire(), goal)}
    end
  end

  def handle_event("set_provider", %{"provider" => provider}, socket) do
    {:noreply, assign(socket, provider: provider)}
  end

  def handle_event("set_context", %{"context_source" => source}, socket) do
    {:noreply, assign(socket, context_source: source)}
  end

  def handle_event("toggle_iterate", %{"auto_iterate" => value}, socket) when is_binary(value) do
    {:noreply, assign(socket, auto_iterate: value == "true")}
  end

  def handle_event("toggle_iterate", _params, socket) do
    {:noreply, assign(socket, auto_iterate: !socket.assigns.auto_iterate)}
  end

  def handle_event("set_retries", %{"max_retries" => retries_str}, socket) do
    case Integer.parse(retries_str) do
      {n, _} when n > 0 -> {:noreply, assign(socket, max_retries: ForgeGuard.attempts(n))}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("retry", _params, socket) do
    case {socket.assigns.current_goal, socket.assigns.current_skill_name} do
      {goal, skill_name} when is_binary(goal) and is_binary(skill_name) ->
        {:noreply, begin_retry(socket, ForgeGuard.acquire(), goal, skill_name)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("show_loaded", _params, socket) do
    case socket.assigns.loaded_skill do
      %{code: code} ->
        {:noreply, assign(socket, code: code)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("clear", _params, socket) do
    {:noreply,
     assign(socket,
       messages: [],
       code: nil,
       status: :idle,
       loaded_skill: nil,
       error: nil,
       loading: false,
       current_goal: nil,
       current_skill_name: nil,
       last_failure: nil,
       retries_left: socket.assigns.max_retries
     )}
  end

  def handle_event("submit_action_code", %{"code" => code}, socket) do
    ActionCode.submit(socket, code)
  end

  def handle_event("cancel_action_code", _params, socket) do
    ActionCode.cancel(socket)
  end

  @impl true
  @spec handle_async(atom(), {:ok, term()} | {:exit, term()}, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_async(:forge_step, {:ok, {:ok, result}}, socket) do
    ForgeGuard.release()
    Memory.store(:conversation, "Forge: Generated skill '#{result.name}'", source: "forge")

    socket =
      socket
      |> assign(
        code: result.code,
        status: :loaded,
        loaded_skill: result,
        loading: false,
        error: nil
      )
      |> add_system_msg(
        "Skill '#{result.name}' stayed inside the contained set and loaded without a 2FA code. " <>
          "Permissions: #{inspect(result.permissions)}, Routes: #{inspect(result.routes)}"
      )

    {:noreply, socket}
  end

  def handle_async(:forge_step, {:ok, {:error, reason, code}}, socket) do
    hint = CodeGenerator.error_to_hint(reason)
    retries_left = socket.assigns.retries_left - 1

    socket =
      socket
      |> assign(code: code, error: hint, last_failure: {reason, code})
      |> add_system_msg("Failed: #{hint}")

    {:noreply, next_attempt(socket, next_move(socket, retries_left), reason, retries_left)}
  end

  # Retries are spent. Code that merely failed has nothing more to offer, but code
  # that only failed containment is still staged — it can load if a person approves it.

  def handle_async(:forge_step, {:exit, reason}, socket) do
    ForgeGuard.release()

    socket =
      socket
      |> assign(status: :failed, loading: false, error: "Process crashed: #{inspect(reason)}")
      |> add_system_msg("Generation process crashed: #{inspect(reason)}")

    {:noreply, socket}
  end

  defp exhausted(socket, {:not_contained, violations}, retries_left) do
    listed = Enum.join(violations, ", ")

    %{
      type: :skill_load,
      file_path: "#{socket.assigns.current_skill_name}.ex",
      origin: :generated
    }
    |> then(&ActionCode.request(socket, &1, "Approve generated skill: #{listed}"))
    |> approval_pending(socket, listed, retries_left)
  end

  defp exhausted(socket, _reason, retries_left) do
    assign(socket, status: :failed, loading: false, retries_left: retries_left)
  end

  defp approval_pending({:noreply, socket}, _previous, listed, retries_left) do
    socket
    |> add_system_msg(
      "Left staged in pending/. It calls outside the contained set (#{listed}), " <>
        "so it needs a 2FA code — enter it above, or approve it on a gateway."
    )
    |> assign(status: :failed, loading: false, retries_left: retries_left)
  end

  @busy "Another skill generation is running. Only one runs at a time — try again when it finishes."

  # The LiveView holds the generation lock from the first attempt to the last,
  # so the lock is released when it gives up, succeeds or goes away.
  defp begin_generation(socket, {:error, :forge_busy}, _goal), do: add_system_msg(socket, @busy)

  defp begin_generation(socket, :ok, goal) do
    skill_name = CodeGenerator.derive_skill_name(goal)
    user_msg = %{role: :user, content: goal, timestamp: DateTime.utc_now()}

    socket
    |> assign(
      messages: socket.assigns.messages ++ [user_msg],
      loading: true,
      status: :generating,
      code: nil,
      loaded_skill: nil,
      error: nil,
      current_goal: goal,
      current_skill_name: skill_name,
      last_failure: nil,
      retries_left: socket.assigns.max_retries,
      deadline: ForgeGuard.deadline()
    )
    |> add_system_msg("Generating skill '#{skill_name}'...")
    |> start_forge_step(goal, skill_name, nil)
  end

  defp begin_retry(socket, {:error, :forge_busy}, _goal, _skill_name),
    do: add_system_msg(socket, @busy)

  defp begin_retry(socket, :ok, goal, skill_name) do
    socket
    |> assign(
      loading: true,
      status: :generating,
      retries_left: socket.assigns.max_retries,
      error: nil,
      deadline: ForgeGuard.deadline()
    )
    |> add_system_msg("Retrying generation...")
    |> start_forge_step(goal, skill_name, socket.assigns.last_failure)
  end

  defp next_move(%{assigns: %{auto_iterate: false}}, _retries_left), do: :stop
  defp next_move(_socket, retries_left) when retries_left <= 0, do: :stop

  defp next_move(socket, _retries_left) do
    if ForgeGuard.expired?(socket.assigns.deadline), do: :out_of_time, else: :retry
  end

  defp next_attempt(socket, :retry, _reason, retries_left) do
    %{current_goal: goal, current_skill_name: skill_name, last_failure: last} = socket.assigns

    socket
    |> assign(retries_left: retries_left, status: :generating)
    |> add_system_msg("Auto-retrying (#{retries_left} left)...")
    |> start_forge_step(goal, skill_name, last)
  end

  defp next_attempt(socket, :out_of_time, reason, retries_left) do
    socket
    |> add_system_msg(
      "Stopped: this generation used its #{ForgeGuard.budget_seconds()}s time budget."
    )
    |> next_attempt(:stop, reason, retries_left)
  end

  defp next_attempt(socket, :stop, reason, retries_left) do
    ForgeGuard.release()
    exhausted(socket, reason, retries_left)
  end

  @spec start_forge_step(
          Phoenix.LiveView.Socket.t(),
          String.t(),
          String.t(),
          {term(), String.t() | nil} | nil
        ) :: Phoenix.LiveView.Socket.t()
  defp start_forge_step(socket, goal, skill_name, last_failure) do
    provider = socket.assigns.provider
    context_source = socket.assigns.context_source

    start_async(socket, :forge_step, fn ->
      forge_step(goal, skill_name, context_source, provider, last_failure)
    end)
  end

  # The first attempt generates; the ones after repair what the last one wrote.
  defp forge_step(goal, skill_name, context_source, provider, nil),
    do: CodeGenerator.generate_step(goal, skill_name, context_source, provider, nil)

  defp forge_step(goal, skill_name, context_source, provider, last_failure),
    do: CodeGenerator.retry_step(goal, skill_name, context_source, provider, last_failure)

  @spec add_system_msg(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  defp add_system_msg(socket, content) do
    msg = %{role: :system, content: content, timestamp: DateTime.utc_now()}
    assign(socket, messages: socket.assigns.messages ++ [msg])
  end

  @spec status_label(atom()) :: String.t()
  defp status_label(:idle), do: "Idle"
  defp status_label(:generating), do: "Generating"
  defp status_label(:loaded), do: "Loaded"
  defp status_label(:failed), do: "Failed"
  defp status_label(_), do: "Working"

  @spec status_color(atom()) :: String.t()
  defp status_color(:idle), do: "bg-gray-500"
  defp status_color(:generating), do: "bg-yellow-400 animate-pulse"
  defp status_color(:loaded), do: "bg-green-400"
  defp status_color(:failed), do: "bg-red-400"
  defp status_color(_), do: "bg-blue-400 animate-pulse"
end
