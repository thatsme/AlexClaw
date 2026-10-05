defmodule AlexClaw.Connections.Pools do
  @moduledoc """
  The running pools, one per defined connection (`AlexClaw.Connections.Pool`),
  under `AlexClaw.Connections.Supervisor`. They follow the definitions: the
  control plane calls `sync/1` once a save or a delete has committed, and
  `start_all/0` runs at boot. A connection that cannot connect is down, never
  a crash, and nothing else is affected.
  """
  alias AlexClaw.Connections
  alias AlexClaw.Connections.Pool

  @supervisor AlexClaw.Connections.PoolSupervisor
  @registry AlexClaw.Connections.Registry

  @doc """
  Make the pool of the connection `name` match its definition: started for a
  new one, restarted for a changed one, stopped for one that is gone.
  """
  @spec sync(String.t()) :: :ok
  def sync(name) do
    stop(name)

    case Connections.get_by_name(name) do
      {:ok, conn} -> start(conn)
      {:error, :not_found} -> :ok
    end
  end

  @doc "Start a pool for every defined connection that has none."
  @spec start_all() :: :ok
  def start_all do
    Connections.list_connections()
    |> Enum.reject(&whereis(&1.name))
    |> Enum.each(&start/1)
  end

  @doc "Stop every pool."
  @spec stop_all() :: :ok
  def stop_all do
    @registry
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.each(&stop/1)
  end

  @doc "The state of the connection `name`'s pool, or nil if it has none."
  @spec status(String.t()) :: Pool.status() | nil
  def status(name) do
    case whereis(name) do
      nil -> nil
      pid -> Pool.status(pid)
    end
  end

  @doc """
  The state of every defined connection, by name; a connection whose pool is
  not running is down.
  """
  @spec statuses() :: [Pool.status()]
  def statuses, do: Enum.map(Connections.list_connections(), &status_of/1)

  defp status_of(conn),
    do:
      status(conn.name) ||
        %{name: conn.name, host: conn.host, state: :down, reason: "not running", pool_size: 0}

  @doc "The Postgrex pool to query the connection `name` through."
  @spec pool(String.t()) :: {:ok, pid()} | {:error, {:connection_down, String.t()}}
  def pool(name) do
    case whereis(name) do
      nil -> {:error, {:connection_down, "no pool is running for #{name}"}}
      pid -> Pool.pool(pid)
    end
  end

  @doc "Run `SELECT 1` on the connection `name`."
  @spec check(String.t()) :: :ok | {:error, term()}
  def check(name) do
    with {:ok, pool} <- pool(name),
         {:ok, _result} <- Postgrex.query(pool, "SELECT 1", [], timeout: 5_000) do
      :ok
    end
  end

  @doc "The pool process of the connection `name`, or nil."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(name) do
    case Registry.lookup(@registry, name) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  defp start(conn) do
    {:ok, _pid} = DynamicSupervisor.start_child(@supervisor, {Pool, conn})
    :ok
  end

  defp stop(name) do
    case whereis(name) do
      nil -> :ok
      pid -> stopped(DynamicSupervisor.terminate_child(@supervisor, pid))
    end
  end

  defp stopped(:ok), do: :ok
  defp stopped({:error, :not_found}), do: :ok
end
