defmodule AlexClawWeb.AdminLive.Forge do
  @moduledoc "Interactive skill generation with real-time feedback. Uses RAG context from the knowledge base."

  use Phoenix.LiveView

  alias AlexClaw.{LLM, Memory}
  alias AlexClaw.Skills.CodeGenerator

  @default_max_retries 5

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
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
       error_context: nil
     )}
  end

  @impl true
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("send", %{"goal" => goal}, socket) do
    goal = String.trim(goal)

    if goal == "" do
      {:noreply, socket}
    else
      skill_name = CodeGenerator.derive_skill_name(goal)
      user_msg = %{role: :user, content: goal, timestamp: DateTime.utc_now()}

      socket =
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
          error_context: nil,
          retries_left: socket.assigns.max_retries
        )
        |> add_system_msg("Generating skill '#{skill_name}'...")
        |> start_forge_step(goal, skill_name, nil)

      {:noreply, socket}
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
      {n, _} when n > 0 and n <= 20 -> {:noreply, assign(socket, max_retries: n)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("retry", _params, socket) do
    case {socket.assigns.current_goal, socket.assigns.current_skill_name} do
      {goal, skill_name} when is_binary(goal) and is_binary(skill_name) ->
        socket =
          socket
          |> assign(
            loading: true,
            status: :generating,
            retries_left: socket.assigns.max_retries,
            error: nil
          )
          |> add_system_msg("Retrying generation...")
          |> start_forge_step(goal, skill_name, socket.assigns.error_context)

        {:noreply, socket}

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
       error_context: nil,
       retries_left: socket.assigns.max_retries
     )}
  end

  @impl true
  @spec handle_async(atom(), {:ok, term()} | {:exit, term()}, Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_async(:forge_step, {:ok, {:ok, result}}, socket) do
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
      |> add_system_msg("Skill '#{result.name}' loaded. Permissions: #{inspect(result.permissions)}, Routes: #{inspect(result.routes)}")

    {:noreply, socket}
  end

  def handle_async(:forge_step, {:ok, {:error, reason, code}}, socket) do
    hint = CodeGenerator.error_to_hint(reason)
    retries_left = socket.assigns.retries_left - 1

    socket =
      socket
      |> assign(code: code, error: hint, error_context: hint)
      |> add_system_msg("Failed: #{hint}")

    if socket.assigns.auto_iterate and retries_left > 0 do
      socket =
        socket
        |> assign(retries_left: retries_left, status: :generating)
        |> add_system_msg("Auto-retrying (#{retries_left} left)...")
        |> start_forge_step(socket.assigns.current_goal, socket.assigns.current_skill_name, hint)

      {:noreply, socket}
    else
      {:noreply, assign(socket, status: :failed, loading: false, retries_left: retries_left)}
    end
  end

  def handle_async(:forge_step, {:exit, reason}, socket) do
    socket =
      socket
      |> assign(status: :failed, loading: false, error: "Process crashed: #{inspect(reason)}")
      |> add_system_msg("Generation process crashed: #{inspect(reason)}")

    {:noreply, socket}
  end

  @spec start_forge_step(Phoenix.LiveView.Socket.t(), String.t(), String.t(), String.t() | nil) :: Phoenix.LiveView.Socket.t()
  defp start_forge_step(socket, goal, skill_name, error_context) do
    provider = socket.assigns.provider
    context_source = socket.assigns.context_source

    start_async(socket, :forge_step, fn ->
      CodeGenerator.generate_step(goal, skill_name, context_source, provider, error_context)
    end)
  end

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
