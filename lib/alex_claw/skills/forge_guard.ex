defmodule AlexClaw.Skills.ForgeGuard do
  @moduledoc """
  Bounds skill generation: one at a time, a time budget across all of its
  attempts, and a hard cap on the attempts themselves.

  A generation is a chain of local-model calls. Left unbounded, a Forge run
  retrying against two local model servers kept the GPU saturated until the
  host ran out of wired memory and had to be powered off.

  A second generation is refused rather than queued: a queued one only brings
  the same load back later. The lock belongs to the process that took it and
  is released when that process exits, so a crashed or closed Forge cannot
  hold it.
  """
  use GenServer

  alias AlexClaw.Config

  @max_attempts 5
  @default_budget_seconds 600

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_arg), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Take the generation lock for `owner`. Not re-entrant: an owner holding it is refused too."
  @spec acquire(pid()) :: :ok | {:error, :forge_busy}
  def acquire(owner \\ self()), do: GenServer.call(__MODULE__, {:acquire, owner})

  @doc "Release the lock if `owner` holds it."
  @spec release(pid()) :: :ok
  def release(owner \\ self()), do: GenServer.call(__MODULE__, {:release, owner})

  @doc "Run `fun` holding the lock, or refuse with `{:error, :forge_busy}`."
  @spec run((-> result)) :: result | {:error, :forge_busy} when result: term()
  def run(fun) do
    with :ok <- acquire() do
      result = fun.()
      release()
      result
    end
  end

  @doc "The attempts a generation may make: the request, within 1..#{@max_attempts}."
  @spec attempts(term()) :: pos_integer()
  def attempts(requested) when is_integer(requested),
    do: requested |> max(1) |> min(@max_attempts)

  def attempts(_requested), do: @max_attempts

  @doc "The hard cap on attempts per generation."
  @spec max_attempts() :: pos_integer()
  def max_attempts, do: @max_attempts

  @doc "Seconds a generation may take across all attempts (`forge.time_budget_seconds`)."
  @spec budget_seconds() :: pos_integer()
  def budget_seconds, do: positive(Config.get("forge.time_budget_seconds"))

  @doc "The monotonic deadline for a generation starting now."
  @spec deadline() :: integer()
  def deadline, do: System.monotonic_time(:millisecond) + budget_seconds() * 1000

  @doc "Whether `deadline` has passed."
  @spec expired?(integer()) :: boolean()
  def expired?(deadline), do: System.monotonic_time(:millisecond) >= deadline

  defp positive(n) when is_integer(n) and n > 0, do: n
  defp positive(_), do: @default_budget_seconds

  @impl true
  def init(nil), do: {:ok, nil}

  @impl true
  def handle_call({:acquire, owner}, _from, nil) do
    {:reply, :ok, {owner, Process.monitor(owner)}}
  end

  def handle_call({:acquire, _owner}, _from, held), do: {:reply, {:error, :forge_busy}, held}

  def handle_call({:release, owner}, _from, {owner, ref}) do
    Process.demonitor(ref, [:flush])
    {:reply, :ok, nil}
  end

  def handle_call({:release, _owner}, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, {_owner, ref}), do: {:noreply, nil}
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}
end
