defmodule AlexClaw.Connections.Pool do
  @moduledoc """
  One connection's pool, and its state: up, or down with the reason.

  Before the pool starts, one connection is opened and closed on its own
  (`Postgrex.SimpleConnection`, synchronously) — the only way to learn why a
  connect fails, which the pool's connections only log. A failure is the
  reason the connection is down; it is tried again after a delay that doubles
  up to a minute. The check runs in a task, so the state can always be read.

  The pool has two connections — AlexClaw's own resource, not a customer
  option. Its password is resolved from OpenBao before every connect, for the
  connection's binding, and held by nothing here. When the password is
  rotated (`{:secret_rotated, name}` on `AlexClaw.Secrets.topic/0`) the pool's
  connections are closed and reconnect with the new one. Once started, the
  pool reconnects on its own; the connections it reports connected and
  disconnected make the state.
  """
  use GenServer

  alias AlexClaw.Connections.{Connection, ConnectionSecrets, Target}
  alias AlexClaw.Secrets

  @pool_size 2
  @connect_timeout 5_000
  @first_retry 1_000
  @last_retry 60_000

  @type status :: %{
          name: String.t(),
          host: String.t(),
          state: :up | :down,
          reason: String.t() | nil,
          pool_size: pos_integer()
        }

  @spec start_link(Connection.t()) :: GenServer.on_start()
  def start_link(%Connection{name: name} = conn),
    do: GenServer.start_link(__MODULE__, conn, name: via(name))

  @spec child_spec(Connection.t()) :: Supervisor.child_spec()
  def child_spec(%Connection{name: name} = conn),
    do: %{id: {__MODULE__, name}, start: {__MODULE__, :start_link, [conn]}, restart: :permanent}

  @doc "The registered name of the pool for the connection `name`."
  @spec via(String.t()) :: GenServer.name()
  def via(name), do: {:via, Registry, {AlexClaw.Connections.Registry, name}}

  @doc "The connection's state."
  @spec status(GenServer.server()) :: status()
  def status(server), do: GenServer.call(server, :status)

  @doc "The Postgrex pool to run a query on, or why there is none."
  @spec pool(GenServer.server()) :: {:ok, pid()} | {:error, {:connection_down, String.t()}}
  def pool(server), do: GenServer.call(server, :pool)

  @impl true
  def init(conn) do
    # The pool and the checks are linked; their exits are messages here.
    Process.flag(:trap_exit, true)
    Phoenix.PubSub.subscribe(AlexClaw.PubSub, Secrets.topic())
    send(self(), :check)

    {:ok,
     %{
       conn: conn,
       pool: nil,
       check: nil,
       connected: %{},
       reason: "not connected yet",
       retry: @first_retry
     }}
  end

  @impl true
  def handle_call(:status, _from, s), do: {:reply, describe(s), s}
  def handle_call(:pool, _from, s), do: {:reply, usable(s), s}

  @impl true
  def handle_info(:check, s), do: {:noreply, %{s | check: Task.async(fn -> check(s.conn) end)}}

  def handle_info({ref, result}, %{check: %Task{ref: ref}} = s) do
    Process.demonitor(ref, [:flush])
    {:noreply, checked(result, %{s | check: nil})}
  end

  def handle_info({:connected, pid}, s),
    do: {:noreply, %{s | connected: Map.put(s.connected, pid, true), retry: @first_retry}}

  def handle_info({:disconnected, pid}, s),
    do:
      {:noreply,
       %{s | connected: Map.delete(s.connected, pid), reason: "lost its connection; reconnecting"}}

  def handle_info({:secret_rotated, name}, s), do: {:noreply, rotated(name, s)}

  def handle_info({:EXIT, pool, reason}, %{pool: pool} = s),
    do: {:noreply, down(%{s | pool: nil, connected: %{}}, "the pool stopped: #{inspect(reason)}")}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{check: %Task{ref: ref}} = s),
    do: {:noreply, down(%{s | check: nil}, "the connection check failed: #{inspect(reason)}")}

  # The check's own exit, the probe connection's, and other secrets' rotations.
  def handle_info(_message, s), do: {:noreply, s}

  defp rotated(name, %{conn: conn, pool: pool} = s) when is_pid(pool) do
    if name == ConnectionSecrets.secret_name(conn) do
      DBConnection.disconnect_all(pool, 0)
      %{s | reason: "password changed; reconnecting"}
    else
      s
    end
  end

  defp rotated(_name, s), do: s

  defp describe(s) do
    %{
      name: s.conn.name,
      host: s.conn.host,
      state: state(s),
      reason: reason(s),
      pool_size: @pool_size
    }
  end

  defp state(%{connected: connected}) when map_size(connected) > 0, do: :up
  defp state(_s), do: :down

  defp reason(%{connected: connected}) when map_size(connected) > 0, do: nil
  defp reason(%{reason: reason}), do: reason

  defp usable(%{pool: pool, connected: connected}) when is_pid(pool) and map_size(connected) > 0,
    do: {:ok, pool}

  defp usable(%{reason: reason}), do: {:error, {:connection_down, reason}}

  defp checked(:ok, s) do
    {:ok, pool} = Postgrex.start_link(pool_options(s.conn))
    %{s | pool: pool, reason: "connecting"}
  end

  defp checked({:error, reason}, s), do: down(s, reason)

  defp down(s, reason) do
    Process.send_after(self(), :check, s.retry)
    %{s | reason: reason, retry: min(s.retry * 2, @last_retry)}
  end

  defp check(conn) do
    # A probe that cannot connect exits; its error is the answer, not a crash.
    Process.flag(:trap_exit, true)

    with :ok <- Target.check(conn.host),
         {:ok, password} <- password(conn) do
      conn
      |> connect_options()
      |> Keyword.merge(password: password, sync_connect: true, auto_reconnect: false)
      |> probe()
    end
  end

  defp password(conn) do
    case ConnectionSecrets.resolve(conn) do
      {:ok, password} ->
        {:ok, password}

      {:error, reason} ->
        {:error, "the password could not be read from OpenBao: #{inspect(reason)}"}
    end
  end

  defp probe(options) do
    case Postgrex.SimpleConnection.start_link(__MODULE__.Probe, nil, options) do
      {:ok, pid} -> :gen_statem.stop(pid)
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  defp pool_options(conn) do
    conn
    |> connect_options()
    |> Keyword.merge(
      pool_size: @pool_size,
      connection_listeners: [self()],
      configure: fn options -> Keyword.put(options, :password, password!(conn)) end
    )
  end

  # Before each connect of the pool: the host is checked again (a name can
  # resolve elsewhere since), then the password read. Either failing fails
  # that connect; the pool retries, and the state says it is down.
  defp password!(conn) do
    :ok = Target.check(conn.host)
    {:ok, password} = ConnectionSecrets.resolve(conn)
    password
  end

  @doc false
  @spec connect_options(Connection.t()) :: keyword()
  def connect_options(%Connection{} = conn) do
    [
      hostname: conn.host,
      port: conn.port,
      database: conn.database,
      username: conn.username,
      ssl: ssl(conn.tls_mode),
      # Decoding never raises on an infinite date or timestamp (M5).
      types: AlexClaw.Connections.PostgrexTypes,
      connect_timeout: @connect_timeout,
      parameters: [application_name: "alexclaw"]
    ]
  end

  # `true` is Postgrex's verified TLS: the system's CAs, the host name checked.
  defp ssl("disable"), do: false
  defp ssl("require"), do: [verify: :verify_none]
  defp ssl("verify_full"), do: true

  defmodule Probe do
    @moduledoc false
    # A connection opened only to learn whether one can be: it does nothing.
    @behaviour Postgrex.SimpleConnection

    @impl true
    def init(_args), do: {:ok, nil}

    @impl true
    def notify(_channel, _payload, _state), do: :ok

    @impl true
    def handle_connect(state), do: {:noreply, state}

    @impl true
    def handle_disconnect(state), do: {:noreply, state}

    @impl true
    def handle_info(_message, state), do: {:noreply, state}

    @impl true
    def handle_result(_result, state), do: {:noreply, state}
  end
end
