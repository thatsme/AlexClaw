defmodule AlexClaw.Connections.Query do
  @moduledoc """
  The SQL behind a `sql_query` step, on a defined connection's pool
  (reports/SQL_READ_PREMISES.md §4.2).

  Both functions work inside one read-only transaction (`SET TRANSACTION READ
  ONLY`) with the server's own deadline (`statement_timeout`, set with a
  bound parameter), so a write is refused by the server — inside a function
  too — and a query past its deadline is cancelled there.

  `dry_run/3` is what a save runs. The statement must start as a read
  (SELECT, WITH, VALUES, TABLE). Preparing it gives the database's own
  errors and the types of its parameters and columns, all of which must be
  supported (`AlexClaw.Connections.Types`), with distinct column names; the
  literal parameters must fit their types. `EXPLAIN` with the literals bound
  and the parameters from the input as NULL checks the privileges and
  refuses a plan that writes or locks. Nothing is executed.

  `run/4` is what a step runs: the parameters coerced to their types, the
  rows streamed and mapped to JSON, counting their size: past the cap
  (5 MB) the result is an error — never a cut. The query runs in a process
  of its own the caller gives up on just after the deadline (killing it
  closes the connection, which cancels the query on the server) in case the
  server's own deadline did not answer. That process's memory is bounded,
  shared binaries included: a value far over the cap ends it before it is
  all in memory, and the result is the size error.

  Nothing a query does to its session outlives it: once its transaction is
  over, the connection is reset (`DISCARD ALL` — session advisory locks,
  settings, prepared statements, cursors) before it goes back to the pool,
  and a connection that cannot be reset is closed.

  An error is `{:sql_error, sqlstate, text}`. PostgreSQL's DETAIL is never
  kept (it can hold row values), and for the classes whose message quotes the
  data — data exceptions (22) and integrity violations (23) — only the
  condition's name is. Any other failure is stated —
  `{:connection_down, why}`, or `{:query_failed, kind}` naming the
  exception, never its message (it can quote a value) — and never reported
  as a timeout.
  """
  require Logger

  alias AlexClaw.Connections.{Pools, Types}

  @max_bytes 5_000_000
  @save_deadline_ms 5_000
  @margin_ms 2_000
  @chunk_rows 50
  # The query process's memory, shared binaries included: fifty times the cap,
  # never less than the floor. Measured at the 5 MB cap (2026-10-07), the
  # narrowest rows need the most per byte of JSON: one one-character text
  # column 150 MB (31x), one one-digit integer 125 MB, one NULL 100 MB; wide
  # rows 30 MB. A statement with no columns, whose rows would cost more still,
  # is refused.
  @heap_factor 50
  @heap_floor_bytes 32_000_000
  @read_starts ~w(select with values table)
  @writes ["ModifyTable", "LockRows"]

  @type param :: {:literal, term()} | :from_input
  @type reason ::
          {:sql_error, String.t() | nil, String.t()}
          | {:not_read_only, String.t()}
          | {:unsupported_type, String.t(), String.t()}
          | {:duplicate_columns, [String.t()]}
          | {:bad_param, pos_integer(), String.t()}
          | {:param_count, non_neg_integer(), non_neg_integer()}
          | {:result_too_large, pos_integer()}
          | {:unencodable, String.t()}
          | {:connection_down, String.t()}
          | {:query_failed, String.t()}
          | :timeout

  @doc """
  Check `query` on the connection `name` as a save does, with `params` as
  the step declares them. Returns the columns and parameter types, or the
  reason it would not run.
  """
  @spec dry_run(String.t(), String.t(), [param()]) ::
          {:ok, %{columns: [map()], params: [String.t()]}} | {:error, reason()}
  def dry_run(name, query, params) do
    with :ok <- read_start(query),
         {:ok, pool} <- Pools.pool(name) do
      guarded(fn -> read_only(pool, @save_deadline_ms, &planned(&1, query, params)) end)
    end
  end

  @doc """
  Run `query` on the connection `name` with the JSON `params`. Options:
  `deadline_ms` (required). Returns `%{"columns", "rows", "row_count"}`.
  """
  @spec run(String.t(), String.t(), [term()], keyword()) :: {:ok, map()} | {:error, reason()}
  def run(name, query, params, opts) do
    deadline = Keyword.fetch!(opts, :deadline_ms)
    # A test sets a smaller cap; a step never passes one.
    max_bytes = Keyword.get(opts, :max_bytes, @max_bytes)

    with :ok <- read_start(query),
         {:ok, pool} <- Pools.pool(name) do
      AlexClaw.TaskSupervisor
      |> Task.Supervisor.async_nolink(fn -> bounded(pool, deadline, query, params, max_bytes) end)
      |> awaited(deadline, max_bytes)
    end
  end

  # The query's own process, its memory bounded (M3).
  defp bounded(pool, deadline, query, params, max_bytes) do
    Process.flag(:max_heap_size, heap_limit(max_bytes))
    guarded(fn -> read_only(pool, deadline, &fetched(&1, query, params, max_bytes)) end)
  end

  defp heap_limit(max_bytes) do
    bytes = max(max_bytes * @heap_factor, @heap_floor_bytes)

    %{
      size: div(bytes, :erlang.system_info(:wordsize)),
      kill: true,
      error_logger: false,
      include_shared_binaries: true
    }
  end

  # Killed by its memory bound, the process was holding more than the cap.
  defp awaited(task, deadline, max_bytes) do
    case Task.yield(task, deadline + @margin_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, :killed} -> {:error, {:result_too_large, max_bytes}}
      {:exit, _reason} -> {:error, {:query_failed, "exit"}}
      nil -> {:error, :timeout}
    end
  end

  @doc false
  # The boundary where a failure outside the database's own errors becomes a
  # value (M5). A connection the pool could not hand out is connection_down.
  # Anything else raised here is AlexClaw's own bug: it is logged by kind and
  # place (F6) — never its message or the arguments in its stack, which can
  # quote a value — and the step is told the kind.
  @spec guarded((-> {:ok, term()} | {:error, term()})) :: {:ok, term()} | {:error, term()}
  def guarded(fun) do
    fun.()
  rescue
    e in DBConnection.ConnectionError ->
      {:error, {:connection_down, Exception.message(e)}}

    e ->
      kind = inspect(e.__struct__)
      Logger.error("sql_query failed in AlexClaw (#{kind}):\n" <> place(__STACKTRACE__))
      {:error, {:query_failed, kind}}
  end

  # The stack with every argument list replaced by its arity.
  defp place(stacktrace) do
    stacktrace
    |> Enum.map(&without_arguments/1)
    |> Exception.format_stacktrace()
  end

  defp without_arguments({module, fun, args, location}) when is_list(args),
    do: {module, fun, length(args), location}

  defp without_arguments(entry), do: entry

  # --- The statement ---

  defp read_start(query) do
    if first_word(query) in @read_starts,
      do: :ok,
      else:
        {:error,
         {:not_read_only, "a sql_query step reads: start with SELECT, WITH, VALUES or TABLE"}}
  end

  defp first_word(query) do
    query
    |> String.replace(~r{\A(\s+|--[^\n]*\n?|/\*.*?\*/)*}s, "")
    |> String.split(~r/[^A-Za-z]/, parts: 2)
    |> List.first()
    |> String.downcase()
  end

  # --- The transaction ---

  # One checkout: the read-only transaction, then the reset (M1).
  defp read_only(pool, deadline, fun) do
    pool
    |> DBConnection.run(&transaction_then_reset(&1, pool, deadline, fun),
      timeout: deadline + @margin_ms
    )
    |> finished()
  end

  # The reset runs however the transaction ended — committed, rolled back or
  # raised — before the connection goes back to the pool.
  defp transaction_then_reset(conn, pool, deadline, fun) do
    Postgrex.transaction(conn, &in_transaction(&1, deadline, fun), timeout: deadline + @margin_ms)
  after
    reset(Postgrex.query(conn, "DISCARD ALL", []), pool)
  end

  defp in_transaction(conn, deadline, fun) do
    with {:ok, _} <- Postgrex.query(conn, "SET TRANSACTION READ ONLY", []),
         {:ok, _} <-
           Postgrex.query(conn, "SELECT set_config('statement_timeout', $1, true)", [
             Integer.to_string(deadline)
           ]),
         {:ok, value} <- fun.(conn) do
      value
    else
      {:error, reason} -> Postgrex.rollback(conn, reason)
    end
  end

  # A session that could not be reset is not handed out again.
  defp reset({:ok, _result}, _pool), do: :ok
  defp reset({:error, _reason}, pool), do: DBConnection.disconnect_all(pool, 0)

  defp finished({:ok, value}), do: {:ok, value}
  defp finished({:error, reason}), do: {:error, error(reason)}

  # --- Save: prepare, check types and literals, explain ---

  defp planned(conn, query, params) do
    with {:ok, prepared} <- Postgrex.prepare(conn, "", query),
         {:ok, shape} <- shape(conn, prepared),
         {:ok, bound} <- literals(shape.params, params),
         {:ok, plan} <- Postgrex.query(conn, "EXPLAIN (FORMAT JSON) " <> query, bound),
         :ok <- reads(plan) do
      Postgrex.close(conn, prepared)
      {:ok, shape}
    end
  end

  defp literals(types, params) when length(types) != length(params),
    do: {:error, {:param_count, length(types), length(params)}}

  defp literals(types, params) do
    types
    |> Enum.zip(params)
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, &literal/2)
    |> reversed()
  end

  defp literal({{_type, :from_input}, _n}, {:ok, acc}), do: {:cont, {:ok, [nil | acc]}}

  defp literal({{type, {:literal, value}}, n}, {:ok, acc}) do
    case Types.coerce(type, value) do
      {:ok, coerced} -> {:cont, {:ok, [coerced | acc]}}
      {:error, reason} -> {:halt, {:error, {:bad_param, n, reason}}}
    end
  end

  defp reversed({:ok, list}), do: {:ok, Enum.reverse(list)}
  defp reversed(error), do: error

  defp reads(%Postgrex.Result{rows: [[plan]]}) do
    case Enum.find(node_types(plan), &(&1 in @writes)) do
      nil -> :ok
      node -> {:error, {:not_read_only, "its plan #{verb(node)}: a sql_query step only reads"}}
    end
  end

  defp verb("ModifyTable"), do: "writes"
  defp verb("LockRows"), do: "locks rows"

  defp node_types(%{"Node Type" => type} = node),
    do: [type | Enum.flat_map(Map.get(node, "Plans", []), &node_types/1)]

  defp node_types(%{"Plan" => plan}), do: node_types(plan)
  defp node_types(list) when is_list(list), do: Enum.flat_map(list, &node_types/1)
  defp node_types(_other), do: []

  # The parameters' and columns' types, every one supported, the names distinct,
  # and at least one column.
  defp shape(conn, %Postgrex.Query{param_oids: param_oids, columns: columns, result_oids: oids}) do
    columns = columns || []

    with :ok <- some_columns(columns),
         {:ok, params} <- typed(conn, param_oids, &"$#{&1}"),
         {:ok, types} <- typed(conn, oids || [], &"column #{Enum.at(columns, &1 - 1)}"),
         :ok <- distinct(columns) do
      {:ok,
       %{
         params: params,
         columns: Enum.zip_with(columns, types, &%{"name" => &1, "type" => &2})
       }}
    end
  end

  defp typed(conn, oids, label) do
    oids
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {oid, n}, {:ok, acc} ->
      case Types.name(oid) do
        nil -> {:halt, {:error, {:unsupported_type, label.(n), type_name(conn, oid)}}}
        type -> {:cont, {:ok, [type | acc]}}
      end
    end)
    |> reversed()
  end

  defp type_name(conn, oid) do
    case Postgrex.query(conn, "SELECT format_type($1, NULL)", [oid]) do
      {:ok, %{rows: [[name]]}} -> name
      {:error, _reason} -> "oid #{oid}"
    end
  end

  # A statement that returns no columns reads nothing a step can use — and
  # SELECT … INTO returns none: it creates a table.
  defp some_columns([]),
    do: {:error, {:not_read_only, "it returns no columns: a sql_query step reads rows"}}

  defp some_columns(_columns), do: :ok

  defp distinct(columns) do
    case columns -- Enum.uniq(columns) do
      [] -> :ok
      twice -> {:error, {:duplicate_columns, Enum.uniq(twice)}}
    end
  end

  # --- Run: coerce, stream, map, count ---

  defp fetched(conn, query, params, max_bytes) do
    with {:ok, prepared} <- Postgrex.prepare(conn, "", query),
         {:ok, shape} <- shape(conn, prepared),
         {:ok, values} <- coerced(shape.params, params),
         {:ok, rows} <- streamed(conn, prepared, values, shape.columns, max_bytes) do
      {:ok, %{"columns" => shape.columns, "rows" => rows, "row_count" => length(rows)}}
    end
  end

  defp coerced(types, params) when length(types) != length(params),
    do: {:error, {:param_count, length(types), length(params)}}

  defp coerced(types, params) do
    types
    |> Enum.zip(params)
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {{type, value}, n}, {:ok, acc} ->
      case Types.coerce(type, value) do
        {:ok, coerced} -> {:cont, {:ok, [coerced | acc]}}
        {:error, reason} -> {:halt, {:error, {:bad_param, n, reason}}}
      end
    end)
    |> reversed()
  end

  # Postgrex reports an error inside a stream only by raising: the boundary
  # where a database error becomes a value.
  defp streamed(conn, prepared, values, columns, max_bytes) do
    conn
    |> Postgrex.stream(prepared, values, max_rows: @chunk_rows)
    |> Enum.reduce_while({:ok, [], 0}, &chunk(&1, &2, columns, max_bytes))
    |> rows()
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, e}
  end

  defp chunk(%Postgrex.Result{rows: rows}, {:ok, acc, bytes}, columns, max_bytes) do
    mapped = Enum.map(rows, &row(&1, columns))

    case Jason.encode_to_iodata(mapped) do
      {:ok, json} -> counted(bytes + IO.iodata_length(json), mapped, acc, max_bytes)
      {:error, _reason} -> {:halt, {:error, {:unencodable, unencodable(mapped, columns)}}}
    end
  end

  defp counted(total, _mapped, _acc, max_bytes) when total > max_bytes,
    do: {:halt, {:error, {:result_too_large, max_bytes}}}

  defp counted(total, mapped, acc, _max_bytes), do: {:cont, {:ok, [mapped | acc], total}}

  # The column holding a value JSON cannot carry: named, the value never.
  defp unencodable(mapped, columns) do
    columns
    |> Enum.map(& &1["name"])
    |> Enum.find(fn name -> Enum.any?(mapped, &match?({:error, _}, Jason.encode(&1[name]))) end)
  end

  defp rows({:ok, chunks, _bytes}), do: {:ok, chunks |> Enum.reverse() |> Enum.concat()}
  defp rows(error), do: error

  defp row(values, columns) do
    columns
    |> Enum.zip(values)
    |> Map.new(fn {%{"name" => name, "type" => type}, value} ->
      {name, Types.to_json(type, value)}
    end)
  end

  # --- Errors: no row data ---

  defp error(%Postgrex.Error{postgres: %{pg_code: "57014"}}), do: :timeout

  defp error(%Postgrex.Error{
         postgres: %{pg_code: <<class::binary-size(2), _::binary>> = code} = pg
       })
       when class in ["22", "23"],
       do: {:sql_error, code, Atom.to_string(pg.code)}

  defp error(%Postgrex.Error{postgres: %{pg_code: code, message: message}}),
    do: {:sql_error, code, message}

  defp error(%Postgrex.Error{} = e), do: {:sql_error, nil, Exception.message(e)}
  defp error(%DBConnection.ConnectionError{} = e), do: {:connection_down, Exception.message(e)}
  defp error(reason), do: reason
end
