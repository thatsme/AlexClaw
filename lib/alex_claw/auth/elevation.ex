defmodule AlexClaw.Auth.Elevation do
  @moduledoc """
  Time-boxed authority to change the control plane from the admin UI.

  A session authenticated with the admin password can read every page. Changing
  what the agent does unattended — configuration, authorization policies, LLM
  providers, API resources, cluster membership, workflows — needs an elevation
  on top: one second factor, verified once, good for fifteen minutes.

  The window is fixed. It does not slide with activity: fifteen minutes after
  the code was accepted the session is read-only again, busy or idle.

  Elevation is keyed by `elevation_sid`, a random value placed in the Plug
  session at login and dropped at logout. Only a fingerprint of it reaches the
  audit log or a PubSub topic — the sid is a session credential, and a
  credential written somewhere durable is a credential leaked.

  `required?/0` answers whether elevation means anything on this instance. With
  no second factor configured there is nothing to verify, so writes proceed and
  every gated page says so in a banner. That bootstrap hole is deliberate and
  documented in SECURITY.md; it is the reason `auth.totp.*` is not editable
  from the Config page at any elevation.
  """
  use GenServer

  alias AlexClaw.Auth.{AuditLog, TOTP}

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
  Whether elevation is enforced on this instance.

  False when no second factor is configured, because there would be nothing to
  verify and the gate would lock the operator out of their own settings.
  """
  @spec required?() :: boolean()
  def required?, do: TOTP.enabled?()

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

  @doc "Grant `sid` a fifteen-minute window, and say when it ends."
  @spec grant(String.t()) :: {:ok, integer()}
  def grant(sid) when is_binary(sid), do: GenServer.call(__MODULE__, {:grant, sid})

  @doc "End `sid`'s elevation now. A session holding none is not an error."
  @spec revoke(String.t() | nil) :: :ok
  def revoke(nil), do: :ok
  def revoke(sid) when is_binary(sid), do: GenServer.call(__MODULE__, {:revoke, sid})

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
    AuditLog.log_elevation(:granted, fingerprint(sid), "window #{@window_seconds}s")
    broadcast(sid, {:elevation, :granted, deadline})
    {:reply, {:ok, deadline}, state}
  end

  def handle_call({:revoke, sid}, _from, state) do
    {:reply, end_elevation(:revoked, sid), state}
  end

  @impl true
  def handle_info(:sweep, state) do
    for sid <- expired(now()), do: end_elevation(:expired, sid)
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

  defp drop([], _reason, _sid), do: :ok

  defp drop([_row], reason, sid) do
    :ets.delete(@table, sid)
    AuditLog.log_elevation(reason, fingerprint(sid), nil)
    broadcast(sid, {:elevation, :ended, reason})
    :ok
  end

  defp broadcast(sid, message) do
    Phoenix.PubSub.broadcast(AlexClaw.PubSub, topic(sid), message)
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval)

  defp now, do: System.system_time(:second)
end
