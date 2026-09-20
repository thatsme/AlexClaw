defmodule AlexClaw.TaskDrain do
  @moduledoc """
  Wait for work handed to `AlexClaw.TaskSupervisor` to finish.

  The table owners — `Auth.Elevation`, `Auth.CodeAttempts` — hand their audit
  and gateway calls to a supervised task on purpose: a process holding a
  `:protected` security table must not be the one waiting on a database. The
  task therefore outlives the call that started it, which is the whole point in
  production and a problem in exactly one place.

  That place is the sandbox. Ownership is checked out per test, and a task
  still writing its row when the owner is stopped fails whichever test was
  unlucky enough to be next. Draining before `stop_owner/1` removes the race
  without touching the behaviour being tested — the task is never the property
  under test, only a consequence of it.

  The timeout is a ceiling, not a wait: a suite with nothing outstanding pays
  one call to `Task.Supervisor.children/1`.
  """

  @poll_ms 10

  @doc "Block until no supervised tasks remain, or `timeout` has passed."
  @spec drain(timeout: non_neg_integer()) :: :ok
  def drain(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 2_000)
    drain_until(System.monotonic_time(:millisecond) + timeout)
  end

  defp drain_until(deadline) do
    AlexClaw.TaskSupervisor
    |> Task.Supervisor.children()
    |> still_running(deadline, System.monotonic_time(:millisecond))
  end

  defp still_running([], _deadline, _now), do: :ok
  defp still_running(_children, deadline, now) when now >= deadline, do: :ok

  defp still_running(_children, deadline, _now) do
    Process.sleep(@poll_ms)
    drain_until(deadline)
  end
end
