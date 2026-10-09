defmodule AlexClaw.Skills.SqlQueryTest do
  @moduledoc """
  The `sql_query` workflow step (reports/SQL_READ_PREMISES.md §4.2): a fixed,
  parameterised read on a defined connection.

  - Saving the step runs the dry run: an undefined connection, a query the
    database cannot plan, a write, a missing deadline or a malformed
    parameter is refused at save, with the reason — so a saved step runs.
  - Running it gives `{columns, rows, row_count}`; parameters come from
    literals or from the step's input; zero rows take the empty route, an
    error the error route.
  - A connection a step uses cannot be removed.
  - Every run is audited — the connection, how many parameters and where
    from, how many rows — never a parameter's value or a row.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :vault

  alias AlexClaw.Auth.AuditLog
  alias AlexClaw.{Connections, Workflows}
  alias AlexClaw.Connections.Pools
  alias AlexClaw.Skills.Invoke
  alias AlexClaw.Workflows.Executor
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    Sandbox.mode(AlexClaw.Repo, {:shared, self()})
    on_exit(fn -> Pools.stop_all() end)

    repo = Application.fetch_env!(:alex_claw, AlexClaw.Repo)

    {:ok, conn} =
      Connections.create_connection(%{
        name: "steps",
        host: repo[:hostname],
        port: repo[:port] || 5432,
        database: repo[:database],
        username: repo[:username],
        tls_mode: "disable",
        password: repo[:password]
      })

    :ok = Pools.sync(conn.name)
    up(conn.name, 50)

    {:ok, wf} = Workflows.create_workflow(%{name: "sql-#{System.unique_integer([:positive])}"})
    %{conn: conn, wf: wf}
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

  defp step(wf, config) do
    Workflows.add_step(wf, %{
      name: "Read",
      skill: "sql_query",
      config: Map.merge(%{"connection" => "steps", "timeout_ms" => 5_000}, config)
    })
  end

  defp config_errors({:error, %Ecto.Changeset{} = changeset}),
    do: changeset.errors |> Keyword.get_values(:config) |> Enum.map_join(" | ", &elem(&1, 0))

  # Values the probe query returns; one appears only as a row, one only as a
  # parameter, so the audit row can be searched for both.
  @row_value "row-value-7c1f"
  @param_value "param-value-9a2e"

  describe "saving a step" do
    test "a query the database can plan is saved", %{wf: wf} do
      assert {:ok, _step} =
               step(wf, %{
                 "query" => "SELECT $1::text AS label, n FROM generate_series(1, 3) n",
                 "params" => [%{"from_input" => "label"}]
               })
    end

    test "an undefined connection is refused, naming it", %{wf: wf} do
      result = step(wf, %{"connection" => "nowhere", "query" => "SELECT 1 AS n"})
      assert {:error, _} = result
      assert inspect(elem(result, 1).errors) =~ "connection"
    end

    test "a query the database cannot plan is refused with the database's reason", %{wf: wf} do
      result = step(wf, %{"query" => "SELECT no_such_column FROM generate_series(1, 2) n"})
      assert config_errors(result) =~ "no_such_column"
    end

    test "a write is refused", %{wf: wf} do
      result =
        step(wf, %{"query" => "WITH d AS (DELETE FROM workflows RETURNING id) SELECT id FROM d"})

      assert config_errors(result) =~ "only reads"
    end

    test "a deadline is required, and is a positive number of milliseconds", %{wf: wf} do
      assert {:error, _} =
               Workflows.add_step(wf, %{
                 name: "Read",
                 skill: "sql_query",
                 config: %{"connection" => "steps", "query" => "SELECT 1 AS n"}
               })

      assert config_errors(step(wf, %{"query" => "SELECT 1 AS n", "timeout_ms" => 0})) =~
               "timeout_ms"
    end

    test "a parameter is a JSON literal or {\"from_input\": key}", %{wf: wf} do
      for bad <- [%{"from_input" => 5}, %{"from_input" => "a", "also" => 1}, %{"secret" => "x"}] do
        result = step(wf, %{"query" => "SELECT $1::text AS v", "params" => [bad]})
        assert config_errors(result) =~ "params", "#{inspect(bad)} was accepted"
      end
    end

    test "the parameters must match the query's", %{wf: wf} do
      result = step(wf, %{"query" => "SELECT $1::text AS a, $2::text AS b", "params" => ["x"]})
      assert config_errors(result) =~ "2"
    end

    test "a literal that does not fit its type is refused", %{wf: wf} do
      result = step(wf, %{"query" => "SELECT $1::int AS n", "params" => ["seven"]})
      assert config_errors(result) =~ "$1"
    end
  end

  describe "running a step" do
    test "gives columns, rows and a row count; parameters from literals and the input", %{wf: wf} do
      {:ok, _} =
        step(wf, %{
          "query" => "SELECT $1::text AS label, n FROM generate_series(1, $2::int) n ORDER BY n",
          "params" => [%{"from_input" => "label"}, 2]
        })

      assert {:ok, run} = Executor.run_with_initial_input(wf.id, %{"label" => "x"})

      assert run.result["output"] == %{
               "columns" => [
                 %{"name" => "label", "type" => "text"},
                 %{"name" => "n", "type" => "int4"}
               ],
               "rows" => [%{"label" => "x", "n" => 1}, %{"label" => "x", "n" => 2}],
               "row_count" => 2
             }
    end

    test "\"$\" passes the whole input as one parameter", %{wf: wf} do
      {:ok, _} =
        step(wf, %{
          "query" => "SELECT ($1::jsonb)->>'k' AS k",
          "params" => [%{"from_input" => "$"}]
        })

      assert {:ok, run} = Executor.run_with_initial_input(wf.id, %{"k" => "v"})
      assert run.result["output"]["rows"] == [%{"k" => "v"}]
    end

    test "a key missing from the input is an error naming it", %{wf: wf} do
      {:ok, _} =
        step(wf, %{"query" => "SELECT $1::text AS v", "params" => [%{"from_input" => "since"}]})

      assert {:error, run} = Executor.run_with_initial_input(wf.id, %{"other" => 1})
      assert inspect(run.step_results) =~ "since"
    end

    test "zero rows take the empty route", %{wf: wf} do
      {:ok, _} = step(wf, %{"query" => "SELECT n FROM generate_series(1, 3) n WHERE n < 0"})

      # An empty route ends the run; a success would go on to this step, which
      # fails: so a completed run is the empty branch, not a success.
      {:ok, _} =
        Workflows.add_step(wf, %{
          name: "Then",
          skill: "sql_query",
          config: %{
            "connection" => "steps",
            "timeout_ms" => 5_000,
            "query" => "SELECT (1 / (n - n))::int AS boom FROM generate_series(1, 1) n"
          }
        })

      assert {:ok, run} = Executor.run(wf.id)
      assert run.status == "completed"
      assert run.result["output"]["row_count"] == 0
    end

    test "a database error takes the error route", %{wf: wf} do
      {:ok, _} =
        step(wf, %{"query" => "SELECT (1 / (n - n))::int AS boom FROM generate_series(1, 1) n"})

      assert {:error, run} = Executor.run(wf.id)
      assert run.status == "failed"
      assert inspect(run.step_results) =~ "22012"
    end

    test "every run is audited, without a parameter's value or a row", %{wf: wf} do
      {:ok, _} =
        step(wf, %{
          "query" => "SELECT '#{@row_value}'::text AS v, $1::text AS p",
          "params" => [%{"from_input" => "p"}]
        })

      assert {:ok, _run} = Executor.run_with_initial_input(wf.id, %{"p" => @param_value})

      [row] = Enum.filter(AuditLog.recent(limit: 50), &(&1.permission == "sql.run"))
      assert row.decision == "allow"
      assert row.reason =~ "steps"
      assert row.reason =~ "1 parameter"
      assert row.reason =~ "from_input"
      assert row.reason =~ "1 row"
      refute row.reason =~ @param_value
      refute row.reason =~ @row_value
    end
  end

  describe "the connection" do
    test "a connection a step uses cannot be removed, naming the workflow", %{conn: conn, wf: wf} do
      {:ok, _} = step(wf, %{"query" => "SELECT 1 AS n"})

      assert {:error, {:in_use, [name]}} = Connections.delete_connection(conn)
      assert name == wf.name
      assert {:ok, _} = Connections.get_by_name(conn.name)
    end

    test "the step is not privileged: it runs from any entry point that may run the workflow" do
      refute "sql_query" in Invoke.privileged_skills()
    end
  end
end
