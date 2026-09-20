defmodule AlexClaw.Auth.CodeAttempts do
  @moduledoc """
  Brute-force limits for codes typed into the web UI.

  A six-digit code is a million guesses, which a script exhausts in minutes if
  nothing counts the wrong ones. Two limits count them, and they answer
  different attacks:

    * **Per session** — three wrong codes lock that session's code entry for
      five minutes. This is the honest-mistake limit, and it is per session so
      one operator fumbling their phone does not lock the instance.

    * **Per instance** — ten wrong codes inside fifteen minutes, across every
      session, lock all web code entry for fifteen minutes. This is the limit
      that matters: a session identifier is a cookie an attacker controls, so a
      per-session limit alone is defeated by discarding the cookie.

  Both live here rather than in LiveView state, for the same reason: state a
  caller owns is state an attacker can drop. The table is `:protected`, so a
  process that is not this one can read the counters and cannot move them.

  A successful code clears that session's counter and leaves the instance
  counter alone — a real operator succeeding says nothing about the attempts
  that came from elsewhere.
  """
  use GenServer

  require Logger

  alias AlexClaw.Auth.AuditLog
  alias AlexClaw.Gateway.Router

  @table :admin_code_attempts

  @session_limit 3
  @session_lock_seconds 5 * 60

  @instance_limit 10
  @instance_window_seconds 15 * 60
  @instance_lock_seconds 15 * 60

  @type lock :: {:locked, :session | :instance, integer()}

  # --- Client ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Whether `sid` may submit a code right now.

  Reads only. The two-argument form takes the moment to judge against, which is
  how the lock boundaries are tested without waiting five minutes.
  """
  @spec status(String.t() | nil) :: :ok | lock()
  def status(sid), do: status(sid, now())

  @spec status(String.t() | nil, integer()) :: :ok | lock()
  def status(sid, now) do
    with :ok <- locked(:instance, instance_lock(), now) do
      locked(:session, session_lock(sid), now)
    end
  end

  @doc "Count one wrong code, and say what that has locked."
  @spec record_failure(String.t() | nil) :: :ok | lock()
  def record_failure(sid), do: GenServer.call(__MODULE__, {:failure, sid, now()})

  @doc "Forget a session's wrong codes. The instance counter is untouched."
  @spec record_success(String.t() | nil) :: :ok
  def record_success(sid), do: GenServer.call(__MODULE__, {:success, sid})

  @doc false
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  @doc "How many wrong codes a session may still send before it is locked."
  @spec session_limit() :: pos_integer()
  def session_limit, do: @session_limit

  @doc "How many wrong codes the instance tolerates inside its window."
  @spec instance_limit() :: pos_integer()
  def instance_limit, do: @instance_limit

  # --- Server ---

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:failure, sid, now}, _from, state) do
    {:reply, count(sid, now), state}
  end

  def handle_call({:success, sid}, _from, state) do
    :ets.delete(@table, {:session, sid})
    {:reply, :ok, state}
  end

  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  # --- Internals ---

  defp count(sid, now) do
    instance = bump_instance(now)
    session = bump_session(sid, now)

    first_lock(instance, session)
  end

  defp first_lock({:locked, _kind, _until} = lock, _session), do: lock
  defp first_lock(:ok, session), do: session

  defp bump_session(sid, now) do
    failures = session_failures(sid) + 1

    :ets.insert(
      @table,
      {{:session, sid}, failures,
       lock_until(failures, @session_limit, now, @session_lock_seconds)}
    )

    lock_reply(:session, failures, @session_limit, now, @session_lock_seconds)
  end

  # The window slides: only the failures still inside it count, so an attacker
  # cannot accumulate nine over a day and then have one more lock the instance.
  defp bump_instance(now) do
    was_locked? = locked(:instance, instance_lock(), now) != :ok
    recent = [now | recent_instance_failures(now)]
    until = lock_until(length(recent), @instance_limit, now, @instance_lock_seconds)
    :ets.insert(@table, {:instance, recent, until})

    announce(
      lock_reply(:instance, length(recent), @instance_limit, now, @instance_lock_seconds),
      was_locked?
    )
  end

  defp lock_until(count, limit, now, seconds) when count >= limit, do: now + seconds
  defp lock_until(_count, _limit, _now, _seconds), do: nil

  defp lock_reply(kind, count, limit, now, seconds) when count >= limit do
    {:locked, kind, now + seconds}
  end

  defp lock_reply(_kind, _count, _limit, _now, _seconds), do: :ok

  # Said once, when the lock goes on — not once per wrong code after it. An
  # attacker who keeps typing should not be able to turn the notification into
  # the flood.
  defp announce({:locked, :instance, _until} = lock, true), do: lock

  defp announce({:locked, :instance, until} = lock, false) do
    minutes = div(@instance_lock_seconds, 60)

    Logger.warning(
      "Web 2FA code entry locked for #{minutes} minutes: #{@instance_limit} wrong codes " <>
        "inside #{div(@instance_window_seconds, 60)} minutes",
      auth: :denied
    )

    AuditLog.log_code_lockout(@instance_limit, until)
    notify(Router.active_gateways())
    lock
  end

  defp announce(other, _was_locked?), do: other

  defp notify([]), do: :ok

  defp notify(_gateways) do
    Router.broadcast(
      "⚠️ Two-factor code entry in the admin UI is locked for " <>
        "#{div(@instance_lock_seconds, 60)} minutes after #{@instance_limit} wrong codes."
    )

    :ok
  end

  defp session_failures(sid) do
    case :ets.lookup(@table, {:session, sid}) do
      [{_key, failures, _until}] -> failures
      [] -> 0
    end
  end

  defp recent_instance_failures(now) do
    cutoff = now - @instance_window_seconds

    case :ets.lookup(@table, :instance) do
      [{:instance, failures, _until}] -> Enum.filter(failures, &(&1 > cutoff))
      [] -> []
    end
  end

  defp session_lock(sid) do
    case :ets.lookup(@table, {:session, sid}) do
      [{_key, _failures, until}] -> until
      [] -> nil
    end
  end

  defp instance_lock do
    case :ets.lookup(@table, :instance) do
      [{:instance, _failures, until}] -> until
      [] -> nil
    end
  end

  defp locked(_kind, nil, _now), do: :ok
  defp locked(kind, until, now) when until > now, do: {:locked, kind, until}
  defp locked(_kind, _until, _now), do: :ok

  defp now, do: System.system_time(:second)
end
