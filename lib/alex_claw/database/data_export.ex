defmodule AlexClaw.Database.DataExport do
  @moduledoc """
  The application's data as a file a restore can load: JSON, one entry per
  table, every value in PostgreSQL's own text form.

      {"format": "alexclaw-data", "version": 1, "schema": <migration>,
       "tables": {"settings": {"columns": [...], "rows": [[...], ...]}, ...}}

  Credentials held in plain columns are written encrypted — see
  `AlexClaw.Database.Sealed`.

  Text form, because it is exact for every type the schema uses — timestamps,
  JSON, arrays, bytea, pgvector — and a restore casts it back to the column's
  type as the live catalog states it. Rows are in primary-key order, so a row
  that refers to its own table's parent comes after that parent.

  Written in chunks, from a stream, so the export is never held in memory
  whole.
  """

  alias AlexClaw.Database.{DataSet, Sealed}
  alias AlexClaw.Repo
  alias Ecto.Adapters.SQL

  @format "alexclaw-data"
  # 2: every string in a sealed JSON value encrypted in place, the form later
  # releases store credentials in at rest, so they restore this format as is.
  @version 2

  @doc "The format name and version a restore expects."
  @spec format() :: {String.t(), pos_integer()}
  def format, do: {@format, @version}

  @doc """
  Write the export chunk by chunk: `emit.(iodata, acc)` answers the next `acc`.
  Returns the last one — a `Plug.Conn`, when the export is streamed as a
  download.
  """
  @spec write(acc, (iodata(), acc -> acc)) :: acc when acc: term()
  def write(acc, emit) do
    {:ok, acc} = Repo.transaction(fn -> chunks(acc, emit) end, timeout: :infinity)
    acc
  end

  defp chunks(acc, emit) do
    header = [
      ~s({"format":"#{@format}","version":#{@version},"schema":),
      to_string(DataSet.schema_version()),
      ~s(,"tables":{)
    ]

    DataSet.tables()
    |> Enum.with_index()
    |> Enum.reduce(emit.(header, acc), fn {table, index}, acc ->
      write_table(table, index, acc, emit)
    end)
    |> then(&emit.("}}", &1))
  end

  defp write_table(table, index, acc, emit) do
    names = table |> DataSet.columns() |> Enum.map(&elem(&1, 0))

    opening = [
      if(index == 0, do: "", else: ","),
      Jason.encode!(table),
      ~s(:{"columns":),
      Jason.encode!(names),
      ~s(,"rows":[)
    ]

    table
    |> select_as_text(names)
    |> then(&SQL.stream(Repo, &1, [], max_rows: 500))
    |> Stream.flat_map(& &1.rows)
    |> Stream.map(Sealed.sealer(table, names))
    |> Stream.with_index()
    |> Enum.reduce(emit.(opening, acc), fn {row, i}, acc ->
      emit.([if(i == 0, do: "", else: ","), Jason.encode!(row)], acc)
    end)
    |> then(&emit.("]}", &1))
  end

  defp select_as_text(table, names) do
    fields = Enum.map_join(names, ", ", &(DataSet.quote_name(&1) <> "::text"))
    order = table |> DataSet.primary_key() |> Enum.map_join(", ", &DataSet.quote_name/1)
    "SELECT #{fields} FROM #{DataSet.quote_name(table)}" <> order_by(order)
  end

  defp order_by(""), do: ""
  defp order_by(columns), do: " ORDER BY " <> columns
end
