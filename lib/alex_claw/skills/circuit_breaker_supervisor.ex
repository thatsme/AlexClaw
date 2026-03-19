defmodule AlexClaw.Skills.CircuitBreakerSupervisor do
  @moduledoc """
  Supervisor module for circuit breaker infrastructure.
  Starts a DynamicSupervisor for breaker GenServers and a
  lifecycle manager that handles PubSub events and ETS ownership.
  """
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {DynamicSupervisor, name: AlexClaw.Skills.CircuitBreakerDynSup, strategy: :one_for_one},
      AlexClaw.Skills.CircuitBreakerLifecycle
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc "Ensure a circuit breaker is running for the given skill. Idempotent."
  @spec ensure_started(String.t()) :: {:ok, pid()}
  def ensure_started(skill_name) do
    case Registry.lookup(AlexClaw.CircuitBreakerRegistry, skill_name) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(
               AlexClaw.Skills.CircuitBreakerDynSup,
               {AlexClaw.Skills.CircuitBreaker, skill_name}
             ) do
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
        DynamicSupervisor.terminate_child(AlexClaw.Skills.CircuitBreakerDynSup, pid)
        :ets.delete(:circuit_breakers, skill_name)
        require Logger
        Logger.info("[CircuitBreaker] Breaker removed for #{skill_name}")

      [] ->
        :ok
    end
  end
end

defmodule AlexClaw.Skills.CircuitBreakerLifecycle do
  @moduledoc """
  GenServer that owns the circuit breaker ETS table and handles
  PubSub events for skill lifecycle (unload/reload).
  """
  use GenServer
  require Logger

  alias AlexClaw.Skills.{CircuitBreaker, CircuitBreakerSupervisor}

  @ets_table :circuit_breakers
  @pubsub_topic "skills:registry"

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(@ets_table, [:named_table, :public, :set, read_concurrency: true])
    Phoenix.PubSub.subscribe(AlexClaw.PubSub, @pubsub_topic)
    {:ok, %{}}
  end

  @impl true
  def handle_info({:skill_unregistered, name}, state) do
    CircuitBreakerSupervisor.stop_breaker(name)
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
