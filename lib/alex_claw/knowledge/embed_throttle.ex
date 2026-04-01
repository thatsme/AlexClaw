defmodule AlexClaw.Knowledge.EmbedThrottle do
  @moduledoc """
  Simple concurrency limiter for embedding requests.
  Prevents overwhelming Ollama/Finch connection pool when many
  knowledge entries are stored in rapid succession.
  """
  use GenServer

  @max_concurrent 3
  @max_waiting 100

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @spec acquire() :: :ok | :drop
  def acquire do
    GenServer.call(__MODULE__, :acquire, 60_000)
  end

  @spec release() :: :ok
  def release do
    GenServer.cast(__MODULE__, :release)
  end

  @impl true
  def init(_) do
    {:ok, %{active: 0, waiting: :queue.new(), waiting_count: 0}}
  end

  @impl true
  def handle_call(:acquire, from, %{active: active} = state) when active < @max_concurrent do
    {:reply, :ok, %{state | active: active + 1}}
  end

  def handle_call(:acquire, from, %{waiting_count: wc} = state) when wc >= @max_waiting do
    {:reply, :drop, state}
  end

  def handle_call(:acquire, from, %{waiting: q, waiting_count: wc} = state) do
    {:noreply, %{state | waiting: :queue.in(from, q), waiting_count: wc + 1}}
  end

  @impl true
  def handle_cast(:release, %{waiting: q, waiting_count: wc} = state) do
    case :queue.out(q) do
      {{:value, next}, q2} ->
        GenServer.reply(next, :ok)
        {:noreply, %{state | waiting: q2, waiting_count: wc - 1}}

      {:empty, _} ->
        {:noreply, %{state | active: state.active - 1}}
    end
  end
end
