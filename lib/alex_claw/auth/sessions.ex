defmodule AlexClaw.Auth.Sessions do
  @moduledoc """
  Which admin logins are live, decided on the server.

  A login is identified by the `elevation_sid` placed in the Plug session at
  login. This table is the only answer to "is that login still good": it is
  opened when the password is accepted, dropped at logout, and good for eight
  hours from the moment it was opened, busy or idle.

  The session a request or a LiveView carries is never the answer on its own.
  A LiveView mounts from a copy of the session signed into the page, which
  LiveView accepts for two weeks and which logout cannot reach — so a copy
  saying "signed in" proves only that it once was. Every authenticated HTTP
  request and every LiveView mount asks here instead, with the sid the copy
  holds.

  Restarting the node empties the table, which signs everyone out. That is the
  intended consequence of keeping the decision on the server.

  The table is `:protected`: this process writes, everyone reads, and a write
  from anywhere else raises rather than quietly opening a login.
  """
  use GenServer

  alias AlexClaw.Auth.Elevation

  @table :admin_sessions
  @max_age_seconds 8 * 60 * 60
  @sweep_interval :timer.minutes(10)

  # --- Client ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc """
  Open a login for `sid`, as of `opened_at` (now, unless given).

  The moment is a parameter so that an old login can be made without waiting
  eight hours for one.
  """
  @spec open(String.t(), integer()) :: :ok
  def open(sid, opened_at \\ now()) when is_binary(sid) do
    GenServer.call(__MODULE__, {:open, sid, opened_at})
  end

  @doc "End `sid`'s login now. A sid holding none is not an error."
  @spec close(String.t() | nil) :: :ok
  def close(nil), do: :ok
  def close(sid) when is_binary(sid), do: GenServer.call(__MODULE__, {:close, sid})

  @doc """
  Whether `sid` is a live login: opened here, not closed, and younger than
  eight hours. The two-argument form judges against a given moment.
  """
  @spec valid?(String.t() | nil) :: boolean()
  def valid?(sid), do: valid?(sid, now())

  @spec valid?(String.t() | nil, integer()) :: boolean()
  def valid?(sid, now) when is_binary(sid), do: live?(:ets.lookup(@table, sid), now)
  def valid?(_sid, _now), do: false

  @doc "How long a login lasts, in seconds."
  @spec max_age_seconds() :: pos_integer()
  def max_age_seconds, do: @max_age_seconds

  @doc """
  The LiveView socket id for `sid`'s login. Broadcasting `"disconnect"` on it
  closes every page that login has open. Named by fingerprint: a topic is not
  a place for the credential itself.
  """
  @spec socket_id(String.t()) :: String.t()
  def socket_id(sid), do: "admin_session:" <> Elevation.fingerprint(sid)

  # --- Server ---

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:open, sid, opened_at}, _from, state) do
    :ets.insert(@table, {sid, opened_at})
    {:reply, :ok, state}
  end

  def handle_call({:close, sid}, _from, state) do
    :ets.delete(@table, sid)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    :ets.select_delete(@table, [{{:_, :"$1"}, [{:"=<", :"$1", now() - @max_age_seconds}], [true]}])

    schedule_sweep()
    {:noreply, state}
  end

  # --- Internals ---

  defp live?([{_sid, opened_at}], now), do: now - opened_at < @max_age_seconds
  defp live?([], _now), do: false

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval)

  defp now, do: System.system_time(:second)
end
