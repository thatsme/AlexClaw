defmodule AlexClaw.DemoSqlTest do
  @moduledoc """
  The SQL demo's database and workflows (reports/SQL_READ_PREMISES.md §4.4),
  loaded the way the demo container loads them — `psql` over the files in
  `demo/` — into a scratch database of the test stack's server.

  - The data is generated, never real, and the same at every load (a fixed
    seed): customers, products, orders and invoices over about two years, a
    few thousand rows, in several regions, with some invoices past due.
  - The read-only role can read the tables and nothing else, and every
    session it opens is read-only.
  - The two shipped workflows read, summarise and send — and their queries
    pass a save's dry run against this schema, as that role, through a
    defined connection.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :vault

  alias AlexClaw.Connections
  alias AlexClaw.Connections.Pools
  alias AlexClaw.Skills.SqlQuery
  alias Ecto.Adapters.SQL.Sandbox

  @reader_password "demo-reader-Test-1"
  @tables ~w(regions customers products orders order_lines invoices)
  @workflows ~w(weekly-sales-brief overdue-invoices)

  setup_all do
    db = "demo_check_#{System.unique_integer([:positive])}"
    owner!("postgres", "CREATE DATABASE #{db}")
    load!(db)

    on_exit(fn ->
      owner!("postgres", "DROP DATABASE IF EXISTS #{db} WITH (FORCE)")
      owner!("postgres", "DROP ROLE IF EXISTS alexclaw_reader")
    end)

    %{db: db}
  end

  defp repo, do: Application.fetch_env!(:alex_claw, AlexClaw.Repo)

  defp psql!(db, args) do
    {out, status} =
      System.cmd(
        "psql",
        [
          "-v",
          "ON_ERROR_STOP=1",
          "-q",
          "-X",
          "-h",
          repo()[:hostname],
          "-U",
          owner_name(),
          "-d",
          db
        ] ++
          args,
        env: [{"PGPASSWORD", System.fetch_env!("DATABASE_OWNER_PASSWORD")}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    out
  end

  defp owner_name, do: System.fetch_env!("DATABASE_OWNER_USERNAME")
  defp owner!(db, sql), do: psql!(db, ["-c", sql])

  # As the container does: the initdb SQL in order, then the role's script.
  defp load!(db) do
    for file <- ~w(01-schema.sql 02-data.sql) do
      psql!(db, ["-f", "demo/initdb/" <> file])
    end

    psql!(db, ["-v", "reader_password=#{@reader_password}", "-f", "demo/reader.sql"])
  end

  defp scalar(db, sql), do: db |> psql!(["-A", "-t", "-c", sql]) |> String.trim()

  defp fingerprint(db) do
    Map.new(@tables, fn table ->
      {table, scalar(db, "SELECT md5(string_agg(t::text, '|' ORDER BY t::text)) FROM #{table} t")}
    end)
  end

  describe "the data" do
    test "is the same at every load", %{db: db} do
      again = "demo_again_#{System.unique_integer([:positive])}"
      owner!("postgres", "CREATE DATABASE #{again}")
      load!(again)
      on_exit(fn -> owner!("postgres", "DROP DATABASE IF EXISTS #{again} WITH (FORCE)") end)

      assert fingerprint(again) == fingerprint(db)
    end

    test "has the expected shape", %{db: db} do
      count = &String.to_integer(scalar(db, "SELECT count(*) FROM #{&1}"))

      assert count.("regions") >= 4
      assert count.("customers") in 200..500
      assert count.("products") in 20..80
      assert count.("orders") in 2_000..5_000
      assert count.("invoices") == count.("orders")

      span = scalar(db, "SELECT max(ordered_at) - min(ordered_at) FROM orders")
      assert String.to_integer(span) in 690..740

      overdue =
        scalar(db, """
        SELECT count(*) FROM invoices
        WHERE paid_on IS NULL AND due_on < (SELECT max(ordered_at) FROM orders)
        """)

      assert String.to_integer(overdue) in 10..500
    end
  end

  describe "the read-only role" do
    test "reads every table, writes none, and its sessions are read-only", %{db: db} do
      # Each statement its own -c: its own transaction, in one session — so a
      # write after turning the read-only default off meets the grants.
      as_reader = fn sql ->
        commands = sql |> String.split("; ") |> Enum.flat_map(&["-c", &1])

        System.cmd(
          "psql",
          ["-X", "-A", "-t", "-h", repo()[:hostname], "-U", "alexclaw_reader", "-d", db] ++
            commands,
          env: [{"PGPASSWORD", @reader_password}],
          stderr_to_stdout: true
        )
      end

      for table <- @tables do
        assert {_out, 0} = as_reader.("SELECT count(*) FROM #{table}")
      end

      assert {out, _} = as_reader.("SHOW default_transaction_read_only")
      assert String.trim(out) == "on"

      assert {out, status} =
               as_reader.("SET default_transaction_read_only = off; DELETE FROM invoices")

      assert status != 0
      assert out =~ "permission denied"

      assert {out, status} = as_reader.("CREATE TABLE intruder (x int)")
      assert status != 0
      assert out =~ ~r/permission denied|read-only/
    end
  end

  describe "the shipped workflows" do
    setup %{db: db} do
      Sandbox.mode(AlexClaw.Repo, {:shared, self()})
      on_exit(fn -> Pools.stop_all() end)

      {:ok, conn} =
        Connections.create_connection(%{
          name: "demo",
          host: repo()[:hostname],
          port: repo()[:port] || 5432,
          database: db,
          username: "alexclaw_reader",
          tls_mode: "disable",
          password: @reader_password
        })

      :ok = Pools.sync(conn.name)
      up(conn.name, 50)
      :ok
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

    defp workflow(name),
      do: "docs/demo/workflows/#{name}.json" |> File.read!() |> Jason.decode!()

    for name <- @workflows do
      test "#{name} reads, summarises and sends" do
        steps = workflow(unquote(name))["steps"] |> Enum.sort_by(& &1["position"])
        assert Enum.map(steps, & &1["skill"]) == ~w(sql_query llm_transform telegram_notify)
        assert hd(steps)["config"]["connection"] == "demo"
      end

      test "#{name}'s query passes a save's dry run as the read-only role" do
        [sql | _] = workflow(unquote(name))["steps"] |> Enum.sort_by(& &1["position"])
        assert :ok = SqlQuery.validate_config(sql["config"])
        assert :ok = SqlQuery.dry_run(sql["config"])
      end

      test "#{name} returns rows from the demo data" do
        [sql | _] = workflow(unquote(name))["steps"] |> Enum.sort_by(& &1["position"])

        assert {:ok, %{"row_count" => rows}, :on_success} =
                 SqlQuery.run(%{config: sql["config"], input: nil})

        assert rows > 0
      end
    end
  end
end
