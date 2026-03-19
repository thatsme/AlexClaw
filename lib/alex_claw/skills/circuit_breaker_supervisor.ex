defmodule AlexClaw.Skills.CircuitBreakerSupervisor do
  @moduledoc """
  DynamicSupervisor for circuit breaker GenServers.
  Creates the ETS table, manages lifecycle, and subscribes to
  skill registry PubSub events to clean up / reset breakers.
  """
  use DynamicSupervisor
  require Logger

  alias AlexClaw.Skills.CircuitBreaker

  @ets_table :circuit_breakers
  @pubsub_topic "skills:registry"

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc "Ensure a circuit breaker is running for the given skill. Idempotent."
  @spec ensure_started(String.t()) :: {:ok, pid()}
  def ensure_started(skill_name) do
    case Registry.lookup(AlexClaw.CircuitBreakerRegistry, skill_name) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(__MODULE__, {CircuitBreaker, skill_name}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
        end
    end
  end

  @doc "Stop a circuit breaker and clean up its ETS entry."
  @spec stop_breaker(String.t()) :: :ok
  def stop_breaker(skill_name) do
    case Registry.lookup(AlexClaw.CircuitBreakerRegistry, skill_name) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)
        :ets.delete(@ets_table, skill_name)
        Logger.info("[CircuitBreaker] Breaker removed for #{skill_name}")

      [] ->
        :ok
    end
  end

  # --- DynamicSupervisor callbacks ---

  @impl true
  def init(_init_arg) do
    :ets.new(@ets_table, [:named_table, :public, :set, read_concurrency: true])
    Phoenix.PubSub.subscribe(AlexClaw.PubSub, @pubsub_topic)
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  # --- PubSub handlers for skill lifecycle ---

  @doc false
  def handle_info({:skill_unregistered, name}, state) do
    stop_breaker(name)
    {:noreply, state}
  end

  def handle_info({:skill_registered, name}, state) do
    case Registry.lookup(AlexClaw.CircuitBreakerRegistry, name) do
      [{_pid, _}] ->
        CircuitBreaker.reset(name)
        Logger.info("[CircuitBreaker] Breaker reset for reloaded skill #{name}")

      [] ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
