defmodule AlexClaw.Lock do
  @moduledoc """
  One holder at a time, released when the holder exits.

  Work that drives a local model server — generating a skill, answering a
  prompt — must not run twice at once: two such runs kept both model servers
  loaded until the host ran out of memory. A second caller is refused rather
  than queued, with the reason its owner was started with, since a queued run
  only brings the same load back later.

  Started under its own name, one per kind of work:

      {AlexClaw.Lock, name: AlexClaw.LLM.LocalLock, busy: :local_model_busy}
  """
  use GenServer

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: Keyword.fetch!(opts, :name), start: {__MODULE__, :start_link, [opts]}}
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :busy), name: name)
  end

  @doc "Take the lock for `owner`. Not re-entrant: an owner already holding it is refused too."
  @spec acquire(GenServer.name(), pid()) :: :ok | {:error, atom()}
  def acquire(name, owner \\ self()), do: GenServer.call(name, {:acquire, owner})

  @doc "Release the lock if `owner` holds it."
  @spec release(GenServer.name(), pid()) :: :ok
  def release(name, owner \\ self()), do: GenServer.call(name, {:release, owner})

  @doc "Run `fun` holding the lock, or refuse with the lock's busy reason."
  @spec run(GenServer.name(), (-> result)) :: result | {:error, atom()} when result: term()
  def run(name, fun) do
    with :ok <- acquire(name) do
      result = fun.()
      release(name)
      result
    end
  end

  @impl true
  def init(busy), do: {:ok, %{busy: busy, held: nil}}

  @impl true
  def handle_call({:acquire, owner}, _from, %{held: nil} = state) do
    {:reply, :ok, %{state | held: {owner, Process.monitor(owner)}}}
  end

  def handle_call({:acquire, _owner}, _from, state),
    do: {:reply, {:error, state.busy}, state}

  def handle_call({:release, owner}, _from, %{held: {owner, ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:reply, :ok, %{state | held: nil}}
  end

  def handle_call({:release, _owner}, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{held: {_owner, ref}} = state),
    do: {:noreply, %{state | held: nil}}

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}
end
