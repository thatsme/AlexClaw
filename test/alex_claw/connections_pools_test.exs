defmodule AlexClaw.ConnectionsPoolsTest do
  @moduledoc """
  Defined connections, running (reports/SQL_READ_PREMISES.md §4.1).

  One supervised pool per defined connection, size 2. The pools follow the
  definitions through `Connections.Pools.sync/1` (the control plane calls it
  after every save and delete): started for a new connection, restarted for a
  changed one, stopped for a removed one; `start_all/0` starts one for every
  connection at boot.

  The password is read from OpenBao, for the connection's binding, before
  every connect — nothing holds it — and a rotated password makes the pool
  reconnect with the new one.

  Every connection has a status: `:up`, or `:down` with the reason, and a
  connection that cannot connect affects nothing else. The reachable
  connection points at the test stack's database server through an EXPLICIT
  definition, reached the way a customer's database would be.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :vault

  alias AlexClaw.Connections
  alias AlexClaw.Connections.Pools
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    Sandbox.mode(AlexClaw.Repo, {:shared, self()})
    on_exit(fn -> Pools.stop_all() end)

    repo = Application.fetch_env!(:alex_claw, AlexClaw.Repo)

    reachable = %{
      name: "reachable_#{System.unique_integer([:positive])}",
      host: repo[:hostname],
      port: repo[:port] || 5432,
      database: repo[:database],
      username: repo[:username],
      tls_mode: "disable",
      password: repo[:password]
    }

    %{reachable: reachable, repo: repo}
  end

  defp defined(attrs) do
    {:ok, conn} = Connections.create_connection(attrs)
    :ok = Pools.sync(conn.name)
    conn
  end

  # A pool's state settles within its first connect and the check before it.
  defp eventually(name, state, tries \\ 50)

  defp eventually(name, state, 0) do
    status = Pools.status(name)
    assert %{state: ^state} = status, "#{name} is #{inspect(status)}, not #{state}"
    status
  end

  defp eventually(name, state, tries) do
    case Pools.status(name) do
      %{state: ^state} = status ->
        status

      _other ->
        Process.sleep(100)
        eventually(name, state, tries - 1)
    end
  end

  test "a defined connection gets a pool and is up", %{reachable: reachable} do
    conn = defined(reachable)
    assert %{name: name, state: :up, reason: nil, pool_size: 2} = eventually(conn.name, :up)
    assert name == conn.name
  end

  test "a connection that cannot connect is down, with the reason, and the others stay up",
       %{reachable: reachable} do
    up = defined(reachable)
    eventually(up.name, :up)

    down = defined(%{reachable | name: "nowhere", host: "nowhere.invalid"})
    status = eventually(down.name, :down)
    assert is_binary(status.reason) and status.reason != ""

    assert %{state: :up} = Pools.status(up.name)
  end

  test "a wrong password is down, naming no password; the right one brings it up",
       %{reachable: reachable} do
    conn = defined(%{reachable | password: "definitely-Wrong-1"})
    status = eventually(conn.name, :down)
    refute status.reason =~ "definitely-Wrong-1"
    refute status.reason =~ reachable.password

    {:ok, conn} = Connections.update_connection(conn, %{password: reachable.password})
    :ok = Pools.sync(conn.name)
    eventually(conn.name, :up)
  end

  test "a rotated password is read at the next connect, with no sync", %{reachable: reachable} do
    conn = defined(reachable)
    eventually(conn.name, :up)

    # Only the secret changes: the pool hears of the rotation and reconnects,
    # reading the new (wrong) password.
    {:ok, _} = Connections.update_connection(conn, %{password: "rotated-Wrong-2"})
    eventually(conn.name, :down)
  end

  test "a removed connection's pool is stopped", %{reachable: reachable} do
    conn = defined(reachable)
    eventually(conn.name, :up)

    {:ok, _} = Connections.delete_connection(conn)
    :ok = Pools.sync(conn.name)

    assert Pools.status(conn.name) == nil
    refute Enum.any?(Pools.statuses(), &(&1.name == conn.name))
  end

  test "start_all starts a pool for every defined connection", %{reachable: reachable} do
    {:ok, a} = Connections.create_connection(reachable)
    {:ok, b} = Connections.create_connection(%{reachable | name: "second_#{a.id}"})
    assert Pools.status(a.name) == nil

    :ok = Pools.start_all()
    eventually(a.name, :up)
    eventually(b.name, :up)
  end

  test "no connections defined: no pools" do
    :ok = Pools.start_all()
    assert Pools.statuses() == []
  end

  test "a status never holds the password", %{reachable: reachable} do
    conn = defined(reachable)
    eventually(conn.name, :up)
    refute inspect(Pools.statuses()) =~ reachable.password
    refute inspect(:sys.get_state(Pools.whereis(conn.name))) =~ reachable.password
  end
end
