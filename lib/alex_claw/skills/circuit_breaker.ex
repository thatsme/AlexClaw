defmodule AlexClaw.Skills.CircuitBreaker do
  @moduledoc """
  OTP circuit breaker per skill. Wraps skill execution transparently —
  skills have zero awareness of the breaker.

  States: :closed (normal) → :open (failing) → :half_open (testing)

  Uses ETS for lock-free reads on the hot path and Process.send_after
  for reset timers. One GenServer per skill, managed by CircuitBreakerSupervisor.
  """
  use GenServer
  require Logger

  @ets_table :circuit_breakers
  @max_failures Application.compile_env(:alex_claw, [:circuit_breaker, :max_failures], 3)
  @reset_timeout Application.compile_env(:alex_claw, [:circuit_breaker, :reset_timeout], :timer.minutes(5))

  # --- Client API ---

  @doc "Start a circuit breaker GenServer for a skill."
  @spec start_link(String.t()) :: GenServer.on_start()
  def start_link(skill_name) do
    GenServer.start_link(__MODULE__, skill_name, name: via(skill_name))
  end

  @doc """
  Transparent wrapper for skill execution. Checks circuit state,
  executes the function if allowed, records the result.
  Skills see no difference — the breaker is invisible.
  """
  @spec call(String.t(), (-> {:ok, any(), atom()} | {:ok, any()} | {:error, any()})) ::
          {:ok, any(), atom()} | {:ok, any()} | {:error, any()} | {:error, :circuit_open}
  def call(skill_name, fun) do
    AlexClaw.Skills.CircuitBreakerSupervisor.ensure_started(skill_name)

    if allow?(skill_name) do
      case fun.() do
        {:ok, result, branch} ->
          record_success(skill_name)
          {:ok, result, branch}

        {:ok, result} ->
          record_success(skill_name)
          {:ok, result}

        {:error, reason} ->
          record_failure(skill_name, reason)
          {:error, reason}
      end
    else
      {:error, :circuit_open}
    end
  end

  @doc "Check if a skill is allowed to execute. Pure ETS read, no GenServer call."
  @spec allow?(String.t()) :: boolean()
  def allow?(skill_name) do
    case :ets.lookup(@ets_table, skill_name) do
      [{_, :open, _, _, _}] -> false
      _ -> true
    end
  end

  @doc "Return the circuit state for a skill."
  @spec state(String.t()) :: {atom(), non_neg_integer(), any()} | :unknown
  def state(skill_name) do
    case :ets.lookup(@ets_table, skill_name) do
      [{_, state, count, last_error, _}] -> {state, count, last_error}
      [] -> :unknown
    end
  end

  @doc "Force-reset a circuit to :closed. Used when a dynamic skill is reloaded."
  @spec reset(String.t()) :: :ok
  def reset(skill_name) do
    case Registry.lookup(AlexClaw.CircuitBreakerRegistry, skill_name) do
      [{pid, _}] -> GenServer.call(pid, :reset)
      [] -> :ok
    end
  end

  # --- GenServer callbacks ---

  @impl true
  @spec init(String.t()) :: {:ok, map()}
  def init(skill_name) do
    :ets.insert(@ets_table, {skill_name, :closed, 0, nil, DateTime.utc_now()})
    {:ok, %{skill_name: skill_name, timer_ref: nil}}
  end

  @impl true
  @spec handle_cast(term(), map()) :: {:noreply, map()}
  def handle_cast({:record_failure, reason}, state) do
    {_, current_state, count, _, _} = lookup!(state.skill_name)
    new_count = count + 1

    case current_state do
      :closed when new_count >= @max_failures ->
        transition(state, :open, new_count, reason)

      :half_open ->
        transition(state, :open, @max_failures, reason)

      _ ->
        :ets.insert(@ets_table, {state.skill_name, current_state, new_count, reason, DateTime.utc_now()})
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast(:record_success, state) do
    {_, current_state, _, _, _} = lookup!(state.skill_name)

    case current_state do
      :half_open ->
        transition(state, :closed, 0, nil)

      _ ->
        :ets.insert(@ets_table, {state.skill_name, current_state, 0, nil, DateTime.utc_now()})
        {:noreply, state}
    end
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), map()) :: {:reply, :ok, map()}
  def handle_call(:reset, _from, state) do
    cancel_timer(state.timer_ref)
    :ets.insert(@ets_table, {state.skill_name, :closed, 0, nil, DateTime.utc_now()})
    Logger.info("[CircuitBreaker] #{state.skill_name} manually reset to :closed")
    {:reply, :ok, %{state | timer_ref: nil}}
  end

  @impl true
  @spec handle_info(term(), map()) :: {:noreply, map()}
  def handle_info(:half_open, state) do
    :ets.insert(@ets_table, {state.skill_name, :half_open, 0, nil, DateTime.utc_now()})
    Logger.info("[CircuitBreaker] #{state.skill_name} → :half_open (testing)")
    {:noreply, %{state | timer_ref: nil}}
  end

  # --- Internal ---

  defp record_success(skill_name) do
    case Registry.lookup(AlexClaw.CircuitBreakerRegistry, skill_name) do
      [{pid, _}] -> GenServer.cast(pid, :record_success)
      [] -> :ok
    end
  end

  defp record_failure(skill_name, reason) do
    case Registry.lookup(AlexClaw.CircuitBreakerRegistry, skill_name) do
      [{pid, _}] -> GenServer.cast(pid, {:record_failure, reason})
      [] -> :ok
    end
  end

  defp transition(state, :open, count, reason) do
    cancel_timer(state.timer_ref)
    :ets.insert(@ets_table, {state.skill_name, :open, count, reason, DateTime.utc_now()})
    timer_ref = Process.send_after(self(), :half_open, @reset_timeout)

    Logger.error(
      "[CircuitBreaker] #{state.skill_name} → :open after #{count} failures. " <>
        "Last error: #{inspect(reason)}. Auto-retry in #{div(@reset_timeout, 60_000)} min."
    )

    notify_opened(state.skill_name, count, reason)
    {:noreply, %{state | timer_ref: timer_ref}}
  end

  defp transition(state, :closed, count, _reason) do
    cancel_timer(state.timer_ref)
    :ets.insert(@ets_table, {state.skill_name, :closed, count, nil, DateTime.utc_now()})

    Logger.info("[CircuitBreaker] #{state.skill_name} → :closed (recovered)")

    notify_closed(state.skill_name)
    {:noreply, %{state | timer_ref: nil}}
  end

  defp lookup!(skill_name) do
    case :ets.lookup(@ets_table, skill_name) do
      [entry] -> entry
      [] -> {skill_name, :closed, 0, nil, DateTime.utc_now()}
    end
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)

  defp via(skill_name) do
    {:via, Registry, {AlexClaw.CircuitBreakerRegistry, skill_name}}
  end

  defp notify_opened(skill_name, count, reason) do
    Task.Supervisor.start_child(AlexClaw.TaskSupervisor, fn ->
      AlexClaw.Gateway.Router.broadcast(
        "⚡ Circuit *OPEN* for skill `#{skill_name}`\n" <>
          "#{count} consecutive failures. Auto-retry in #{div(@reset_timeout, 60_000)} min.\n" <>
          "Last error: `#{String.slice(inspect(reason), 0, 200)}`"
      )
    end)
  end

  defp notify_closed(skill_name) do
    Task.Supervisor.start_child(AlexClaw.TaskSupervisor, fn ->
      AlexClaw.Gateway.Router.broadcast("✅ Circuit *CLOSED* for skill `#{skill_name}` — recovered.")
    end)
  end
end
