defmodule AlexClaw.Auth.Elevation do
  @moduledoc """
  Time-boxed authority to change the control plane from the admin UI.

  A session authenticated with the admin password can read every page. Changing
  what the agent does unattended — configuration, authorization policies, LLM
  providers, API resources, cluster membership, workflows — needs an elevation
  on top: one second factor, verified once, good for fifteen minutes.

  Elevation is always required. There is no instance state in which a
  control-plane write proceeds on the password alone: with no second factor
  configured, the control plane is read-only and every such write is refused
  until 2FA is set up. That is why the bootstrap path is the environment —
  `TELEGRAM_*` and `DISCORD_*` make a gateway reachable, `/setup 2fa` on that
  gateway configures the second factor — and why there is no variable that
  turns the gate off.

  The window is fixed. It does not slide with activity: fifteen minutes after
  the code was accepted the session is read-only again, busy or idle.

  Elevation is keyed by `elevation_sid`, a random value placed in the Plug
  session at login and dropped at logout. Only a fingerprint of it reaches the
  audit log or a PubSub topic — the sid is a session credential, and a
  credential written somewhere durable is a credential leaked.

  A grant and a revoke are audited by the caller, before it reports success: a
  person has just been told their elevation holds, so the record of it should
  already exist. An expiry has no caller and is recorded by the sweep, off the
  owner process — see `audit_expired/2`.

  `configured?/0` reports whether a second factor exists at all. It never
  decides whether the gate applies, only what a refusal should say: a session
  that cannot elevate yet is told how to make elevation possible.
  """
  use GenServer

  alias AlexClaw.Auth.{AuditLog, Principal, SecondFactor}

  @table :admin_elevations
  @window_seconds 15 * 60
  @sweep_interval :timer.minutes(1)

  @type ended_by :: :revoked | :expired

  # --- Client ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Whether a second factor exists to elevate with.

  Not a question about whether the gate applies — it always does — but about
  whether this instance can answer it yet.
  """
  @spec configured?() :: boolean()
  def configured?, do: SecondFactor.impl().configured?()

  @doc """
  Whether `sid` currently holds an elevation.

  The two-argument form takes the moment to judge against, which is what makes
  the expiry boundary testable without waiting a quarter of an hour.
  """
  @spec elevated?(String.t() | nil) :: boolean()
  def elevated?(sid), do: elevated?(sid, now())

  @spec elevated?(String.t() | nil, integer()) :: boolean()
  def elevated?(nil, _now), do: false
  def elevated?(sid, now) when is_binary(sid), do: live?(:ets.lookup(@table, sid), now)

  @doc """
  Grant `sid` a fifteen-minute window, and say when it ends.

  The audit row is written here, in the caller, before this returns. Someone is
  about to be told their elevation holds, and the record of it should exist by
  the time they are told.
  """
  @spec grant(String.t()) :: {:ok, integer()}
  def grant(sid) when is_binary(sid) do
    {:ok, deadline} = GenServer.call(__MODULE__, {:grant, sid})

    AuditLog.log_elevation(
      :granted,
      fingerprint(sid),
      "window #{@window_seconds}s, principal: #{Principal.current()}"
    )

    {:ok, deadline}
  end

  @doc """
  End `sid`'s elevation now. A session holding none is not an error.

  Audited in the caller, like a grant, and only when something was actually
  dropped — a revoke that found nothing is not an event.
  """
  @spec revoke(String.t() | nil) :: :ok
  def revoke(nil), do: :ok

  def revoke(sid) when is_binary(sid) do
    audit_revoked(GenServer.call(__MODULE__, {:revoke, sid}), sid)
  end

  defp audit_revoked(:dropped, sid) do
    AuditLog.log_elevation(:revoked, fingerprint(sid), nil)
    :ok
  end

  defp audit_revoked(:none, _sid), do: :ok

  @doc """
  End every elevation now: every session was signed out
  (`:sign_out_everywhere`), so none may keep one. Each is audited as revoked.
  """
  @spec revoke_all() :: :ok
  def revoke_all do
    __MODULE__
    |> GenServer.call(:revoke_all)
    |> Enum.each(&audit_revoked(:dropped, &1))
  end

  @doc "When `sid`'s elevation ends, or nil when it holds none."
  @spec expires_at(String.t() | nil) :: integer() | nil
  def expires_at(nil), do: nil
  def expires_at(sid) when is_binary(sid), do: deadline(:ets.lookup(@table, sid))

  @doc "A fresh session identifier, for the Plug session at login."
  @spec new_sid() :: String.t()
  def new_sid, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @doc "The window every grant gets, in seconds."
  @spec window_seconds() :: pos_integer()
  def window_seconds, do: @window_seconds

  @doc """
  A short, non-reversible stand-in for a sid.

  Used wherever a session has to be named — audit rows, PubSub topics — so that
  reading those back never yields the credential itself.
  """
  @spec fingerprint(String.t()) :: String.t()
  def fingerprint(sid) do
    :sha256 |> :crypto.hash(sid) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  @doc "PubSub topic carrying one session's elevation changes."
  @spec topic(String.t()) :: String.t()
  def topic(sid), do: "elevation:" <> fingerprint(sid)

  @doc "Follow `sid`'s elevation: `{:elevation, :granted, expires_at}` and `{:elevation, :ended, reason}`."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(sid), do: Phoenix.PubSub.subscribe(AlexClaw.PubSub, topic(sid))

  @doc false
  @spec expired(integer()) :: [String.t()]
  def expired(now) do
    :ets.select(@table, [{{:"$1", :"$2"}, [{:"=<", :"$2", now}], [:"$1"]}])
  end

  # --- Server ---

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:grant, sid}, _from, state) do
    deadline = now() + @window_seconds
    :ets.insert(@table, {sid, deadline})
    broadcast(sid, {:elevation, :granted, deadline})
    {:reply, {:ok, deadline}, state}
  end

  def handle_call({:revoke, sid}, _from, state) do
    {:reply, end_elevation(:revoked, sid), state}
  end

  def handle_call(:revoke_all, _from, state) do
    sids = :ets.select(@table, [{{:"$1", :_}, [], [:"$1"]}])
    {:reply, Enum.filter(sids, &(end_elevation(:revoked, &1) == :dropped)), state}
  end

  @impl true
  def handle_info(:sweep, state) do
    for sid <- expired(now()), do: audit_expired(end_elevation(:expired, sid), sid)
    schedule_sweep()
    {:noreply, state}
  end

  # --- Internals ---

  defp live?([{_sid, deadline}], now), do: deadline > now
  defp live?([], _now), do: false

  defp deadline([{_sid, deadline}]), do: deadline
  defp deadline([]), do: nil

  # Writes happen here or nowhere: the table is :protected, so a caller outside
  # this process raises rather than quietly ending someone's elevation.
  defp end_elevation(reason, sid), do: drop(:ets.lookup(@table, sid), reason, sid)

  defp drop([], _reason, _sid), do: :none

  defp drop([_row], reason, sid) do
    :ets.delete(@table, sid)
    broadcast(sid, {:elevation, :ended, reason})
    :dropped
  end

  # An expiry has no caller. Nobody asked for it and nobody is waiting to be
  # told it happened, so the sweep is the only thing that can record it — and
  # the sweep runs in the owner, which must not wait on a database. A database
  # that has gone away exits rather than raising, and an exit here would take
  # the :protected table, and every live elevation, with it.
  #
  # Grants and revokes do not come through here. They have a caller, and the
  # caller writes their row before it reports success.
  #
  # Only the fingerprint crosses into the task. The sid is a live session
  # credential and has no business on another process's heap.
  defp audit_expired(:none, _sid), do: :ok

  defp audit_expired(:dropped, sid) do
    fingerprint = fingerprint(sid)

    Task.Supervisor.start_child(AlexClaw.TaskSupervisor, fn ->
      AuditLog.log_elevation(:expired, fingerprint, nil)
    end)

    :ok
  end

  defp broadcast(sid, message) do
    Phoenix.PubSub.broadcast(AlexClaw.PubSub, topic(sid), message)
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval)

  defp now, do: System.system_time(:second)
end
