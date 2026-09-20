defmodule AlexClaw.BootRetry do
  @moduledoc """
  Backoff for work at boot that needs the database to be up.

  The app and postgres start together and one of them wins. A process that
  reads the database on the way up will sometimes find nothing listening, and
  that is a matter of timing rather than a bug — so it is not something to
  crash on. Crashing restarts the process, which queries again, which crashes
  again, and the supervisor's restart intensity turns a boot that was merely
  early into the whole tree going down a few seconds later.

  So the caller keeps an attempt count, asks for a retry when a read fails, and
  carries on. `1s, 2s, 5s`, then every `10s`: fast enough that a database
  arriving a moment later costs nothing, slow enough that one that is properly
  gone does not fill the log.

  Note what an unreachable database actually raises. `DBConnection.ConnectionError`,
  not `Postgrex.Error` — a rescue written for the latter catches a missing
  table and lets a missing server through, which is what both callers here used
  to do.
  """
  require Logger

  @backoff_ms [1_000, 2_000, 5_000]
  @interval_ms 10_000

  @doc """
  Log a failed read, ask for `message` to come back later, and return the next
  attempt count.

  The caller sends itself `message`, so there is no separate timer to track and
  nothing to cancel: a retry is an ordinary `handle_info/2`.
  """
  @spec schedule(term(), non_neg_integer(), String.t(), String.t()) :: pos_integer()
  def schedule(message, attempts, what, reason) do
    delay = delay(attempts)

    Logger.warning(
      "#{what} not loaded (#{reason}); retrying in #{delay}ms (attempt #{attempts + 1})"
    )

    Process.send_after(self(), message, delay)
    attempts + 1
  end

  @doc "The wait before attempt number `attempts + 1`."
  @spec delay(non_neg_integer()) :: pos_integer()
  def delay(attempts) when attempts < length(@backoff_ms), do: Enum.at(@backoff_ms, attempts)
  def delay(_attempts), do: @interval_ms
end
