defmodule AlexClaw.Skills.SqlQuery do
  @moduledoc """
  Core skill: a fixed, parameterised read on a defined database connection
  (reports/SQL_READ_PREMISES.md §4.2).

  Config:
    * `connection` — the name of a connection defined on the Connections page;
    * `query` — one statement starting with SELECT, WITH, VALUES or TABLE, in
      PostgreSQL's `$1, $2…` parameter syntax, never built from data;
    * `params` — in order, each a JSON literal or `{"from_input": key}` (a
      top-level key of the step's input; `"$"` for the whole input);
    * `timeout_ms` — the deadline, required, at most 300 000 (five
      minutes): the server cancels the query there.

  Saving the step runs the dry run (`AlexClaw.Connections.Query.dry_run/3`):
  a step that saved, runs. The step runs in a read-only transaction and gives
  `%{"columns", "rows", "row_count"}`; zero rows take the empty route, an
  error the error route. Every run is audited — the connection, the number of
  parameters and where they came from, the row count — never a value or a
  row. The rows are the database's data: what an LLM step does with them is
  not sanitised.
  """
  @behaviour AlexClaw.Skill

  alias AlexClaw.Auth.AuditLog
  alias AlexClaw.Connections
  alias AlexClaw.Connections.Query

  # A query holds its tables' locks, a pool session and the executor for as
  # long as its deadline.
  @max_timeout_ms 300_000

  @impl true
  def description, do: "Read from a database connection with a fixed, parameterised query"

  @impl true
  def routes, do: [:on_success, :on_empty, :on_error]

  # Its rows come from outside AlexClaw.
  @impl true
  def external, do: true

  @impl true
  def step_fields, do: [:config]

  @impl true
  def config_schema do
    %{
      "connection" => %{type: :string, required: true},
      "query" => %{type: :string, required: true},
      "params" => %{type: :list, required: false},
      "timeout_ms" => %{type: :integer, required: true}
    }
  end

  @impl true
  def config_scaffold,
    do: %{
      "connection" => "",
      "query" => "SELECT id, name FROM customers WHERE region = $1",
      "params" => [%{"from_input" => "region"}],
      "timeout_ms" => 15_000
    }

  @impl true
  def config_hint,
    do:
      ~s|{"connection": "erp", "query": "SELECT … WHERE x = $1", "params": [{"from_input": "x"}], "timeout_ms": 15000}|

  @impl true
  def config_help,
    do:
      "connection: a connection from the Connections page. query: one read (SELECT, WITH, VALUES or TABLE) " <>
        "with $1, $2… for parameters. params: in order, a JSON value or {\"from_input\": key} " <>
        "(\"$\" for the whole input). timeout_ms: the deadline (required, at most 300000)."

  @impl true
  def available?(%{"connection" => name}) when is_binary(name),
    do: match?({:ok, _}, Connections.get_by_name(name))

  def available?(_config), do: true

  @impl true
  def unavailable_reason,
    do: "its connection is not defined: add it on the Connections page first"

  @impl true
  def validate_config(config) do
    case Enum.reject([timeout(config["timeout_ms"]), params(config["params"])], &(&1 == :ok)) do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp timeout(ms) when is_integer(ms) and ms > 0 and ms <= @max_timeout_ms, do: :ok

  defp timeout(ms) when is_integer(ms) and ms > @max_timeout_ms,
    do: "timeout_ms: at most #{@max_timeout_ms} (five minutes)"

  defp timeout(_ms), do: "timeout_ms: must be a positive number of milliseconds"

  defp params(nil), do: :ok

  defp params(list) when is_list(list) do
    if Enum.all?(list, &param?/1),
      do: :ok,
      else: ~s|params: each must be a JSON value or {"from_input": key}|
  end

  defp params(_other), do: "params: must be a list"

  defp param?(%{"from_input" => key} = param) when is_binary(key) and map_size(param) == 1,
    do: true

  # A map is a literal only when it is not trying to be something else.
  defp param?(%{} = map), do: not Enum.any?(~w(from_input secret), &Map.has_key?(map, &1))
  defp param?(_literal), do: true

  @impl true
  def dry_run(%{"connection" => name, "query" => query} = config) do
    declared = Enum.map(config["params"] || [], &declared/1)

    case Query.dry_run(name, query, declared) do
      {:ok, _shape} -> :ok
      {:error, reason} -> {:error, [describe(reason)]}
    end
  end

  defp declared(%{"from_input" => _key}), do: :from_input
  defp declared(value), do: {:literal, value}

  @impl true
  def run(args) do
    config = args[:config] || %{}
    name = config["connection"]
    params = config["params"] || []
    started = System.monotonic_time(:millisecond)

    result =
      with {:ok, values} <- values(params, args[:input]) do
        Query.run(name, config["query"], values, deadline_ms: config["timeout_ms"])
      end

    audit(name, params, started, result)
    routed(result)
  end

  defp values(params, input) do
    params
    |> Enum.reduce_while({:ok, []}, fn param, {:ok, acc} ->
      case value(param, input) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> reversed()
  end

  defp reversed({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reversed(error), do: error

  defp value(%{"from_input" => "$"}, input), do: {:ok, input}

  defp value(%{"from_input" => key}, %{} = input) do
    case Map.fetch(input, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_input, key}}
    end
  end

  defp value(%{"from_input" => key}, _input), do: {:error, {:missing_input, key}}
  defp value(literal, _input), do: {:ok, literal}

  defp audit(name, params, started, result) do
    summary = %{
      sources: Enum.map(params, &source/1),
      ms: System.monotonic_time(:millisecond) - started
    }

    AuditLog.log_sql_run(name, summary, counted(result))
  end

  defp source(%{"from_input" => _key}), do: :from_input
  defp source(_literal), do: :literal

  defp counted({:ok, %{"row_count" => rows}}), do: {:ok, rows}
  defp counted(error), do: error

  defp routed({:ok, %{"row_count" => 0} = result}), do: {:ok, result, :on_empty}
  defp routed({:ok, result}), do: {:ok, result, :on_success}
  defp routed({:error, reason}), do: {:error, reason}

  defp describe({:sql_error, code, text}), do: "the database refused it (#{code}): #{text}"
  defp describe({:not_read_only, why}), do: why

  defp describe({:unsupported_type, what, type}),
    do: "#{what} is of type #{type}, which a sql_query step cannot read: cast it, e.g. ::text"

  defp describe({:duplicate_columns, names}),
    do: "the columns #{Enum.join(names, ", ")} appear twice: give them distinct names (AS)"

  defp describe({:bad_param, n, why}), do: "parameter $#{n} #{why}"

  defp describe({:param_count, expected, given}),
    do: "the query takes #{expected} parameters, the step gives #{given}"

  defp describe({:connection_down, why}), do: "the connection is not available: #{why}"
  defp describe({:query_failed, kind}), do: "the query failed (#{kind})"
  defp describe(:timeout), do: "the database did not answer within the save's 5 seconds"
  defp describe(other), do: "refused: #{inspect(other)}"
end
