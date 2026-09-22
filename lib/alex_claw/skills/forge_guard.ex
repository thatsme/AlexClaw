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
  alias AlexClaw.Config
  alias AlexClaw.Lock

  @max_attempts 5
  @default_budget_seconds 600

  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_arg), do: Lock.child_spec(name: __MODULE__, busy: :forge_busy)

  @doc "Take the generation lock for `owner`. Not re-entrant: an owner holding it is refused too."
  @spec acquire(pid()) :: :ok | {:error, :forge_busy}
  def acquire(owner \\ self()), do: Lock.acquire(__MODULE__, owner)

  @doc "Release the lock if `owner` holds it."
  @spec release(pid()) :: :ok
  def release(owner \\ self()), do: Lock.release(__MODULE__, owner)

  @doc "Run `fun` holding the lock, or refuse with `{:error, :forge_busy}`."
  @spec run((-> result)) :: result | {:error, :forge_busy} when result: term()
  def run(fun), do: Lock.run(__MODULE__, fun)

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
end
