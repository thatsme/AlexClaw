defmodule AlexClaw.Connections.QueryTest do
  @moduledoc """
  The SQL behind a `sql_query` step (reports/SQL_READ_PREMISES.md §3, §4.2,
  §4.3), against a real PostgreSQL reached through a defined connection: the
  test stack's server, as its application role, with fixture tables in a
  schema of their own.

  `dry_run/3` is what a save runs: the database's own errors, read-only
  statements only, supported types only, distinct column names, literal
  parameters that fit their types — and nothing is executed.

  `run/4` is what a step runs: parameters coerced to their types, a read-only
  transaction, a deadline the server enforces, a size cap that is an error
  and never a cut, a fixed mapping to JSON, errors that carry no row data.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :vault

  alias AlexClaw.Connections
  alias AlexClaw.Connections.{Pools, Query}
  alias Ecto.Adapters.SQL.Sandbox

  @schema "sql_fixture"

  setup_all do
    owner = owner_connection()

    for statement <- fixture_sql() do
      Postgrex.query!(owner, statement, [])
    end

    on_exit(fn ->
      cleanup = owner_connection()
      Postgrex.query!(cleanup, "DROP SCHEMA IF EXISTS #{@schema} CASCADE", [])
      GenServer.stop(cleanup)
    end)

    GenServer.stop(owner)
    :ok
  end

  setup do
    Sandbox.mode(AlexClaw.Repo, {:shared, self()})
    on_exit(fn -> Pools.stop_all() end)

    repo = Application.fetch_env!(:alex_claw, AlexClaw.Repo)

    {:ok, conn} =
      Connections.create_connection(%{
        name: "fixture",
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

  defp owner_connection do
    repo = Application.fetch_env!(:alex_claw, AlexClaw.Repo)

    {:ok, pid} =
      Postgrex.start_link(
        hostname: repo[:hostname],
        port: repo[:port] || 5432,
        database: repo[:database],
        username: System.fetch_env!("DATABASE_OWNER_USERNAME"),
        password: System.fetch_env!("DATABASE_OWNER_PASSWORD")
      )

    pid
  end

  defp fixture_sql do
    app = Application.fetch_env!(:alex_claw, AlexClaw.Repo)[:username]

    [
      "DROP SCHEMA IF EXISTS #{@schema} CASCADE",
      "CREATE SCHEMA #{@schema}",
      """
      CREATE TABLE #{@schema}.items (
        id int PRIMARY KEY, name text, price numeric(10,2), uid uuid, made date,
        at_tz timestamptz, at_naive timestamp, active boolean, meta jsonb, blob bytea
      )
      """,
      """
      INSERT INTO #{@schema}.items VALUES
        (1, 'alpha', 12.50, '1b4e28ba-2fa1-11d2-883f-0016d3cca427', '2026-01-15',
         '2026-01-15 10:00:00+00', '2026-01-15 10:00:00', true, '{"k": 1}', '\\x00ff'),
        (2, 'beta', 7.25, NULL, '2026-02-20', NULL, NULL, false, NULL, NULL)
      """,
      "CREATE TABLE #{@schema}.writable (id int, v text)",
      "INSERT INTO #{@schema}.writable VALUES (1, 'before')",
      "CREATE TABLE #{@schema}.no_grant (x int)",
      "CREATE SEQUENCE #{@schema}.counter",
      """
      CREATE FUNCTION #{@schema}.touch() RETURNS int LANGUAGE sql AS
      $$ UPDATE #{@schema}.writable SET v = 'touched' RETURNING 1 $$
      """,
      "GRANT USAGE ON SCHEMA #{@schema} TO #{app}",
      "GRANT SELECT ON #{@schema}.items TO #{app}",
      # The application role may write this one: only the read-only
      # transaction stands between a step and a write.
      "GRANT SELECT, INSERT, UPDATE, DELETE ON #{@schema}.writable TO #{app}",
      "GRANT USAGE, SELECT, UPDATE ON SEQUENCE #{@schema}.counter TO #{app}"
    ]
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

  defp literal(value), do: {:literal, value}

  defp writable_value do
    %{rows: [[value]]} =
      Postgrex.query!(owner_connection(), "SELECT v FROM #{@schema}.writable WHERE id = 1", [])

    value
  end

  describe "dry_run/3: what a save checks" do
    test "a read with a literal and a parameter from the input", %{name: name} do
      assert {:ok, plan} =
               Query.dry_run(
                 name,
                 "SELECT id, name, price FROM #{@schema}.items WHERE made < $1 AND active = $2",
                 [:from_input, literal(true)]
               )

      assert plan.columns == [
               %{"name" => "id", "type" => "int4"},
               %{"name" => "name", "type" => "text"},
               %{"name" => "price", "type" => "numeric"}
             ]

      assert plan.params == ["date", "bool"]
    end

    test "the database's own errors", %{name: name} do
      assert {:error, {:sql_error, "42601", _}} =
               Query.dry_run(name, "SELECT id FROM FROM #{@schema}.items", [])

      assert {:error, {:sql_error, "42703", message}} =
               Query.dry_run(name, "SELECT nope FROM #{@schema}.items", [])

      assert message =~ "nope"

      assert {:error, {:sql_error, "42P01", _}} =
               Query.dry_run(name, "SELECT 1 FROM #{@schema}.missing", [])

      assert {:error, {:sql_error, "42501", _}} =
               Query.dry_run(name, "SELECT x FROM #{@schema}.no_grant", [])

      assert {:error, {:sql_error, "42883", _}} =
               Query.dry_run(name, "SELECT id FROM #{@schema}.items WHERE name > 5", [])
    end

    test "two statements are refused", %{name: name} do
      assert {:error, {:sql_error, "42601", _}} = Query.dry_run(name, "SELECT 1; SELECT 2", [])
    end

    for {label, sql} <- [
          {"an insert", "INSERT INTO sql_fixture.writable VALUES (2, 'x')"},
          {"an update", "UPDATE sql_fixture.writable SET v = 'x'"},
          {"a delete", "DELETE FROM sql_fixture.writable"},
          {"a data-modifying CTE",
           "WITH d AS (DELETE FROM sql_fixture.writable RETURNING id) SELECT * FROM d"},
          {"a row lock", "SELECT id FROM sql_fixture.writable FOR UPDATE"},
          {"a table created from a query", "CREATE TABLE sql_fixture.copy AS SELECT 1 AS a"},
          {"a cursor", "DECLARE c CURSOR FOR SELECT 1"}
        ] do
      test "#{label} is refused as not a read", %{name: name} do
        assert {:error, {:not_read_only, reason}} = Query.dry_run(name, unquote(sql), [])
        assert is_binary(reason)
        assert writable_value() == "before"
      end
    end

    test "WITH, VALUES and TABLE reads are accepted", %{name: name} do
      assert {:ok, _} =
               Query.dry_run(name, "WITH x AS (SELECT 1 AS a) SELECT a FROM x", [])

      assert {:ok, _} = Query.dry_run(name, "VALUES (1, 'a')", [])
      assert {:ok, _} = Query.dry_run(name, "  -- a comment\n  TABLE #{@schema}.writable", [])
    end

    test "a column of an unsupported type is refused, naming it", %{name: name} do
      assert {:error, {:unsupported_type, "column blob", "bytea"}} =
               Query.dry_run(name, "SELECT id, blob FROM #{@schema}.items", [])

      assert {:ok, _} =
               Query.dry_run(
                 name,
                 "SELECT id, encode(blob, 'base64') AS blob FROM #{@schema}.items",
                 []
               )
    end

    test "a parameter of an unsupported type is refused, naming it", %{name: name} do
      assert {:error, {:unsupported_type, "$1", "bytea"}} =
               Query.dry_run(name, "SELECT id FROM #{@schema}.items WHERE blob = $1", [
                 :from_input
               ])
    end

    test "duplicate column names are refused", %{name: name} do
      assert {:error, {:duplicate_columns, ["id"]}} =
               Query.dry_run(
                 name,
                 "SELECT a.id, b.id FROM #{@schema}.items a JOIN #{@schema}.items b USING (id)",
                 []
               )
    end

    test "a literal that does not fit its parameter's type is refused", %{name: name} do
      assert {:error, {:bad_param, 1, _}} =
               Query.dry_run(name, "SELECT id FROM #{@schema}.items WHERE id = $1", [
                 literal("not a number")
               ])
    end

    test "nothing is executed", %{name: name} do
      before =
        Postgrex.query!(owner_connection(), "SELECT last_value FROM #{@schema}.counter", [])

      assert {:ok, _} = Query.dry_run(name, "SELECT nextval('#{@schema}.counter')", [])

      assert Postgrex.query!(owner_connection(), "SELECT last_value FROM #{@schema}.counter", []).rows ==
               before.rows
    end

    test "a connection that is not defined, or down, is an error", %{name: _name} do
      assert {:error, {:connection_down, _}} = Query.dry_run("never_defined", "SELECT 1", [])
    end
  end

  describe "run/4: what a step does" do
    test "the result: columns, rows as objects, row count", %{name: name} do
      assert {:ok, result} =
               Query.run(name, "SELECT id, name FROM #{@schema}.items ORDER BY id", [],
                 deadline_ms: 5_000
               )

      assert result == %{
               "columns" => [
                 %{"name" => "id", "type" => "int4"},
                 %{"name" => "name", "type" => "text"}
               ],
               "rows" => [%{"id" => 1, "name" => "alpha"}, %{"id" => 2, "name" => "beta"}],
               "row_count" => 2
             }

      assert {:ok, _json} = Jason.encode(result)
    end

    test "every supported type maps to JSON", %{name: name} do
      sql = """
      SELECT id, price, uid, made, at_tz, at_naive, active, meta, name, NULL::text AS nothing,
             1.5::float8 AS ratio
      FROM #{@schema}.items WHERE id = 1
      """

      assert {:ok, %{"rows" => [row]}} = Query.run(name, sql, [], deadline_ms: 5_000)

      assert row == %{
               "id" => 1,
               "price" => "12.50",
               "uid" => "1b4e28ba-2fa1-11d2-883f-0016d3cca427",
               "made" => "2026-01-15",
               "at_tz" => "2026-01-15T10:00:00Z",
               "at_naive" => "2026-01-15T10:00:00",
               "active" => true,
               "meta" => %{"k" => 1},
               "name" => "alpha",
               "nothing" => nil,
               "ratio" => 1.5
             }
    end

    test "no rows is an empty result, not an error", %{name: name} do
      assert {:ok, %{"rows" => [], "row_count" => 0}} =
               Query.run(name, "SELECT id FROM #{@schema}.items WHERE id < 0", [],
                 deadline_ms: 5_000
               )
    end

    test "JSON parameters are coerced to their types", %{name: name} do
      sql = """
      SELECT id FROM #{@schema}.items
      WHERE made <= $1 AND at_tz <= $2 AND id = $3 AND price = $4 AND active = $5
        AND uid = $6 AND meta @> $7 AND name = $8
      """

      params = [
        "2026-01-15",
        "2026-01-15T10:00:00Z",
        1,
        "12.50",
        true,
        "1b4e28ba-2fa1-11d2-883f-0016d3cca427",
        %{"k" => 1},
        "alpha"
      ]

      assert {:ok, %{"rows" => [%{"id" => 1}]}} = Query.run(name, sql, params, deadline_ms: 5_000)
    end

    test "a parameter that does not fit its type is an error naming its position", %{name: name} do
      assert {:error, {:bad_param, 2, reason}} =
               Query.run(
                 name,
                 "SELECT id FROM #{@schema}.items WHERE id = $1 AND made = $2",
                 [1, "soon"],
                 deadline_ms: 5_000
               )

      assert is_binary(reason)
    end

    test "the transaction is read-only: a write inside a function is refused", %{name: name} do
      assert {:error, {:sql_error, "25006", _}} =
               Query.run(name, "SELECT #{@schema}.touch()", [], deadline_ms: 5_000)

      assert writable_value() == "before"
    end

    test "the deadline is enforced by the server, and the query stops there", %{name: name} do
      started = System.monotonic_time(:millisecond)
      sleep = "SELECT 1 AS n FROM pg_sleep(5)"
      assert {:error, :timeout} = Query.run(name, sleep, [], deadline_ms: 300)
      # The server's own deadline answers at once; the caller's backstop would
      # only give up two seconds after it.
      assert System.monotonic_time(:millisecond) - started < 1_500

      %{rows: rows} =
        Postgrex.query!(
          owner_connection(),
          "SELECT count(*) FROM pg_stat_activity WHERE query = $1 AND state = 'active'",
          [sleep]
        )

      assert rows == [[0]]
    end

    test "a result over the cap is an error, never a cut", %{name: name} do
      sql = "SELECT g AS n, repeat('x', 100) AS pad FROM generate_series(1, 2000) g"

      assert {:error, {:result_too_large, 20_000}} =
               Query.run(name, sql, [], deadline_ms: 5_000, max_bytes: 20_000)

      assert {:ok, %{"row_count" => 2000}} = Query.run(name, sql, [], deadline_ms: 5_000)
    end

    test "an error carries no row data", %{name: name} do
      # PostgreSQL quotes the offending value in the message of a data error.
      assert {:error, {:sql_error, "22P02", message}} =
               Query.run(name, "SELECT name::int FROM #{@schema}.items", [], deadline_ms: 5_000)

      refute message =~ "alpha"
      refute message =~ "beta"
    end

    test "a connection that is not defined is an error", %{name: _name} do
      assert {:error, {:connection_down, _}} =
               Query.run("never_defined", "SELECT 1", [], deadline_ms: 1_000)
    end
  end
end
