defmodule AlexClaw.Connections.QueryHardeningTest do
  @moduledoc """
  What a query leaves behind, what it may take, and how it fails
  (reports/SQLREAD_ATTACKER_REVIEW.md M1, M3, M5), against the test stack's
  PostgreSQL through a defined connection.

  - M1: nothing a query does to its session outlives it. The connection is
    reset (`DISCARD ALL`) before it goes back to the pool: a session advisory
    lock is released, a session setting is gone.
  - M3: the query runs in a process of its own whose memory is bounded,
    shared binaries included. A value far larger than the cap ends that
    process before it is all in memory; the result is the size error, and
    the caller and the pool carry on.
  - M5: a failure is a stated error, never a timeout that did not happen, and
    no parameter value reaches the log: a parameter outside its type's range
    or not encodable is refused naming its position; a connection the pool
    cannot hand out is `connection_down`.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :vault

  import ExUnit.CaptureLog

  alias AlexClaw.Connections
  alias AlexClaw.Connections.{Pools, Query}
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    Sandbox.mode(AlexClaw.Repo, {:shared, self()})
    on_exit(fn -> Pools.stop_all() end)

    repo = Application.fetch_env!(:alex_claw, AlexClaw.Repo)

    {:ok, conn} =
      Connections.create_connection(%{
        name: "hardening",
        host: repo[:hostname],
        port: repo[:port] || 5432,
        database: repo[:database],
        username: repo[:username],
        tls_mode: "disable",
        password: repo[:password]
      })

    :ok = Pools.sync(conn.name)
    up(conn.name, 50)
    %{name: conn.name}
  end

  defp up(name, 0), do: flunk("#{name} never came up: #{inspect(Pools.status(name))}")

  defp up(name, tries) do
    case Pools.status(name) do
      %{state: :up} ->
        :ok

      _other ->
        Process.sleep(100)
        up(name, tries - 1)
    end
  end

  defp owner_query(sql, params) do
    repo = Application.fetch_env!(:alex_claw, AlexClaw.Repo)

    {:ok, pid} =
      Postgrex.start_link(
        hostname: repo[:hostname],
        port: repo[:port] || 5432,
        database: repo[:database],
        username: System.fetch_env!("DATABASE_OWNER_USERNAME"),
        password: System.fetch_env!("DATABASE_OWNER_PASSWORD")
      )

    %{rows: rows} = Postgrex.query!(pid, sql, params)
    GenServer.stop(pid)
    rows
  end

  describe "M1: nothing outlives the query" do
    test "a session advisory lock is released before the connection is returned", %{name: name} do
      assert {:ok, %{"rows" => [%{"l" => true}]}} =
               Query.run(name, "SELECT pg_try_advisory_lock(424242) AS l", [], deadline_ms: 5_000)

      assert owner_query(
               "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND objid = $1",
               [424_242]
             ) == [[0]]
    end

    test "a session setting does not outlive the query", %{name: name} do
      assert {:ok, _} =
               Query.run(
                 name,
                 "SELECT set_config('application_name', 'leaked_setting', false) AS s",
                 [],
                 deadline_ms: 5_000
               )

      assert owner_query(
               "SELECT count(*) FROM pg_stat_activity WHERE application_name = $1",
               ["leaked_setting"]
             ) == [[0]]
    end
  end

  describe "M3: the query's memory is bounded" do
    test "a value far over the cap ends the query's process before it is all in memory",
         %{name: name} do
      baseline = :erlang.memory(:binary)
      sampler = spawn_link(fn -> sample(baseline) end)

      assert {:error, {:result_too_large, 5_000_000}} =
               Query.run(name, "SELECT repeat('x', 900000000) AS big", [], deadline_ms: 60_000)

      send(sampler, {:peak, self()})
      assert_receive {:peak, peak}, 1_000

      # The bound is 250 MB (fifty times the cap); unbounded, the 900 MB value
      # would be held whole and then joined into one binary.
      assert peak - baseline < 500_000_000,
             "binary memory grew by #{div(peak - baseline, 1_000_000)} MB"

      assert {:ok, %{"row_count" => 1}} = Query.run(name, "SELECT 1 AS n", [], deadline_ms: 5_000)
    end
  end

  defp sample(peak) do
    receive do
      {:peak, from} -> send(from, {:peak, peak})
    after
      2 -> sample(max(peak, :erlang.memory(:binary)))
    end
  end

  describe "M5: failures are stated, and quote no value" do
    test "an integer outside its type's range is refused naming its position", %{name: name} do
      log =
        capture_log(fn ->
          assert {:error, {:bad_param, 1, _why}} =
                   Query.run(name, "SELECT $1::int4 AS n", [99_999_999_999], deadline_ms: 5_000)
        end)

      refute log =~ "99999999999"
    end

    test "a number too large for a float is refused naming its position", %{name: name} do
      huge = Integer.pow(10, 400)

      log =
        capture_log(fn ->
          assert {:error, {:bad_param, 1, _why}} =
                   Query.run(name, "SELECT $1::float8 AS f", [huge], deadline_ms: 5_000)
        end)

      refute log =~ "0000000000"
    end

    test "a JSON parameter that cannot be encoded is refused naming its position", %{name: name} do
      log =
        capture_log(fn ->
          assert {:error, {:bad_param, 1, _why}} =
                   Query.run(name, "SELECT $1::jsonb AS j", [%{"k" => {:not, "json-9871"}}],
                     deadline_ms: 5_000
                   )
        end)

      refute log =~ "json-9871"
    end

    # A value the driver could not decode stopped the connection, and the
    # connection's report quoted it. Infinite dates and timestamps are data.
    test "infinite dates and timestamps are read as infinity, never a failure", %{name: name} do
      sql = """
      SELECT 'infinity'::timestamptz AS a, '-infinity'::timestamp AS b,
             'infinity'::date AS c, '-infinity'::date AS d
      """

      log =
        capture_log(fn ->
          assert {:ok, %{"rows" => [row]}} = Query.run(name, sql, [], deadline_ms: 5_000)

          assert row == %{
                   "a" => "infinity",
                   "b" => "-infinity",
                   "c" => "infinity",
                   "d" => "-infinity"
                 }

          Process.sleep(200)
        end)

      refute log =~ "infinity"
    end
  end
end
