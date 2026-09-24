defmodule AlexClaw.Database.Restore do
  @moduledoc """
  Replacing the application's data with an export — data, never SQL.

  A restore file is what `AlexClaw.Database.DataExport` writes: JSON, holding
  values. It is parsed and checked in the application, and the values are
  inserted through parameterised queries, as text cast to each column's type.
  Nothing in the file is executed, and nothing in it names what is written:
  the tables, their columns and their types come from the live catalog, and a
  file that disagrees with it is refused before anything changes.

  The audit log, the logins and the migrator's bookkeeping are never touched —
  see `AlexClaw.Database.DataSet`. Every other table is emptied and refilled
  from the file in one transaction, so a restore that fails part-way leaves
  the data as it was. Sequences are set past the restored rows.

  It is challenged per action, never covered by an elevation window, and
  audited on both sides: a row before anything runs — no restore without it —
  and a row saying how it ended.

  Every encrypted value in the file is checked to decrypt before anything is
  written — see `AlexClaw.Database.KeyCheck` — so a file made under another
  `SECRET_KEY_BASE` is refused whole.

  A full backup, schema and audit log included, is restored by an operator
  with the database owner's credentials; see the upgrade guide.
  """

  alias AlexClaw.Auth.{AuditLog, Principal}
  alias AlexClaw.Database.{DataExport, DataSet, KeyCheck}
  alias AlexClaw.Repo

  @staging_prefix "alexclaw-restore-"
  @max_params 60_000

  @doc """
  Copy an uploaded file somewhere it will survive until the code is answered.
  Returns the staged path.
  """
  @spec stage(Path.t()) :: {:ok, Path.t()} | {:error, File.posix()}
  def stage(uploaded_path) do
    staged = Path.join(System.tmp_dir!(), @staging_prefix <> token() <> ".json")
    with :ok <- File.cp(uploaded_path, staged), do: {:ok, staged}
  end

  @doc "Discard a staged file — on refusal, or once the restore is done."
  @spec discard(Path.t()) :: :ok
  def discard(path) do
    File.rm(path)
    :ok
  end

  @doc """
  Restore a staged file, then discard it. Audited before and after; a restore
  whose first row cannot be written does not run.

  `context` names the upload and, by fingerprint, the session that asked.
  """
  @spec run(Path.t(), %{filename: String.t(), session: String.t()}) ::
          {:ok, String.t()} | {:error, String.t()}
  def run(path, %{filename: filename, session: session}) do
    detail = "database restore from #{filename}"

    session
    |> AuditLog.record_admin_write(detail)
    |> restore(path, session, detail)
  end

  defp restore(:ok, path, session, detail) do
    result = path |> read() |> loaded()
    discard(path)
    AuditLog.record_admin_outcome(session, "#{detail} — #{message(result)}", Principal.current())
    result
  end

  defp restore({:error, _reason}, path, _session, _detail) do
    discard(path)
    {:error, "The restore was not run: it could not be recorded in the audit log."}
  end

  defp read(path) do
    with {:ok, body} <- read_file(File.read(path)), do: decoded(Jason.decode(body))
  end

  defp read_file({:ok, body}), do: {:ok, body}

  defp read_file({:error, _}),
    do: {:error, "The uploaded file is no longer available — upload it again"}

  defp decoded({:ok, data}), do: {:ok, data}

  defp decoded({:error, _}),
    do: {:error, "The file is not an AlexClaw data export (not valid JSON)"}

  defp loaded({:ok, data}), do: load(data)
  defp loaded(error), do: error

  defp message({:ok, message}), do: message
  defp message({:error, message}), do: message

  @doc """
  Replace the application's data with `data`, a decoded export, in one
  transaction. Refused, with nothing changed, unless every table, column and
  value in it fits the live schema.
  """
  @spec load(term()) :: {:ok, String.t()} | {:error, String.t()}
  def load(data) do
    with {:ok, plan} <- plan(data),
         {:ok, count} <- Repo.transaction(fn -> replace(plan) end, timeout: :infinity) do
      {:ok, "Restore completed: #{count} rows in #{length(plan)} tables"}
    end
  end

  # --- Checking the file ---

  defp plan(%{"format" => format, "version" => version, "schema" => schema, "tables" => tables})
       when is_map(tables) do
    with :ok <- same_format({format, version}),
         {:ok, age} <- schema_age(schema),
         :ok <- known_tables(Map.keys(tables)) do
      DataSet.tables()
      |> Enum.filter(&Map.has_key?(tables, &1))
      |> Enum.reduce_while({:ok, []}, fn table, {:ok, acc} ->
        planned(table_plan(table, tables[table], age), acc)
      end)
      |> reversed()
    end
  end

  defp plan(_data), do: {:error, "The file is not an AlexClaw data export"}

  defp same_format(format) do
    if format == DataExport.format(),
      do: :ok,
      else: {:error, "The file is not an AlexClaw data export of a version this release reads"}
  end

  # A file from this schema restores as it is. One from an older schema
  # restores when the database has only added nullable columns since (checked
  # per table). One from a newer schema never does: this database lacks what
  # that release added.
  defp schema_age(schema) when is_integer(schema),
    do: schema_age(schema, DataSet.schema_version())

  defp schema_age(schema), do: {:error, "The export's schema #{inspect(schema)} is not a version"}

  defp schema_age(same, same), do: {:ok, :same}
  defp schema_age(schema, current) when schema < current, do: {:ok, :older}

  defp schema_age(schema, current),
    do: {:error, "The export was made on schema #{schema}, newer than this database's #{current}"}

  defp known_tables(names) do
    case names -- DataSet.tables() do
      [] ->
        :ok

      unknown ->
        {:error,
         "The export holds tables a restore does not replace: #{Enum.join(Enum.sort(unknown), ", ")}"}
    end
  end

  defp table_plan(table, %{"columns" => columns, "rows" => rows}, age)
       when is_list(columns) and is_list(rows) do
    live = DataSet.columns(table)

    with {:ok, added} <- added_columns(table, columns, Enum.map(live, &elem(&1, 0)), age),
         :ok <- rows_fit(table, rows, length(columns)) do
      checked(table, live, Enum.map(rows, &with_nulls(&1, columns, live, added)))
    end
  end

  defp rows_fit(table, rows, width) do
    if Enum.all?(rows, &row?(&1, width)),
      do: :ok,
      else: {:error, "#{table} holds a row that is not a list of #{width} text values"}
  end

  defp table_plan(table, _entry, _age), do: {:error, "#{table} is not a table entry"}

  # The columns the database has that the file does not. From the same schema
  # there are none. From an older one they are the columns added since, and a
  # restore fills them with null — only when each may be null, the file has no
  # column the database no longer has, and the rest are in the database's order.
  defp added_columns(_table, same, same, _age), do: {:ok, []}

  defp added_columns(table, _columns, _live_names, :same),
    do: {:error, "The columns of #{table} do not match this database"}

  defp added_columns(table, columns, live_names, :older) do
    added = live_names -- columns

    with :ok <- none_gone(table, columns -- live_names),
         :ok <- none_required(table, added -- DataSet.nullable_columns(table)),
         :ok <- same_order(table, columns, live_names -- added) do
      {:ok, added}
    end
  end

  defp none_gone(_table, []), do: :ok

  defp none_gone(table, gone),
    do:
      {:error,
       "#{table}: the export has #{Enum.join(gone, ", ")}, which this database no longer has"}

  defp none_required(_table, []), do: :ok

  defp none_required(table, required),
    do:
      {:error,
       "#{table}: the export lacks #{Enum.join(required, ", ")}, which this database requires"}

  defp same_order(_table, same, same), do: :ok

  defp same_order(table, _columns, _expected),
    do: {:error, "The columns of #{table} are not in this database's order"}

  # A row from the file, in the database's column order, null where a column
  # was added since the export.
  defp with_nulls(row, _columns, _live, []), do: row

  defp with_nulls(row, columns, live, _added) do
    values = columns |> Enum.zip(row) |> Map.new()
    Enum.map(live, fn {name, _type} -> Map.get(values, name) end)
  end

  # Encrypted values must decrypt under this key before anything is written, so
  # a file made under another SECRET_KEY_BASE is refused whole.
  defp checked(table, live, rows) do
    names = Enum.map(live, &elem(&1, 0))

    rows
    |> Enum.find_value(:ok, &refusal(KeyCheck.check(table, names, &1)))
    |> checked_plan(table, live, rows)
  end

  defp refusal(:ok), do: nil
  defp refusal(error), do: error

  defp checked_plan(:ok, table, live, rows), do: {:ok, {table, live, rows}}
  defp checked_plan({:error, reason}, table, _live, _rows), do: {:error, "#{table}: #{reason}"}

  defp row?(row, width) when is_list(row) and length(row) == width,
    do: Enum.all?(row, &(is_binary(&1) or is_nil(&1)))

  defp row?(_row, _width), do: false

  defp planned({:ok, entry}, acc), do: {:cont, {:ok, [entry | acc]}}
  defp planned(error, _acc), do: {:halt, error}

  defp reversed({:ok, plan}), do: {:ok, Enum.reverse(plan)}
  defp reversed(error), do: error

  # --- Replacing the data ---

  defp replace(plan) do
    Repo.query!("TRUNCATE " <> Enum.map_join(DataSet.tables(), ", ", &DataSet.quote_name/1))

    count =
      Enum.reduce(plan, 0, fn {table, columns, rows}, total ->
        total + insert(table, columns, rows)
      end)

    Enum.each(plan, fn {table, columns, _rows} -> reset_sequences(table, columns) end)
    count
  end

  defp insert(_table, _columns, []), do: 0

  defp insert(table, columns, rows) do
    per_query = max(div(@max_params, length(columns)), 1)

    rows
    |> Enum.chunk_every(per_query)
    |> Enum.each(&insert_chunk(table, columns, &1))

    length(rows)
  end

  defp insert_chunk(table, columns, rows) do
    names = Enum.map_join(columns, ", ", fn {name, _type} -> DataSet.quote_name(name) end)
    width = length(columns)

    values =
      rows
      |> Enum.with_index()
      |> Enum.map_join(", ", fn {_row, r} -> "(" <> placeholders(columns, r * width) <> ")" end)

    sql = "INSERT INTO #{DataSet.quote_name(table)} (#{names}) VALUES #{values}"
    inserted(Repo.query(sql, List.flatten(rows)), table)
  end

  defp placeholders(columns, offset) do
    columns
    |> Enum.with_index(offset + 1)
    |> Enum.map_join(", ", fn {{_name, type}, n} -> "$#{n}::text::#{type}" end)
  end

  defp inserted({:ok, _result}, _table), do: :ok

  defp inserted({:error, error}, table) do
    Repo.rollback("#{table} holds a value this database refuses: #{Exception.message(error)}")
  end

  defp reset_sequences(table, columns) do
    Enum.each(columns, fn {name, _type} ->
      %{rows: [[sequence]]} =
        Repo.query!("SELECT pg_get_serial_sequence($1, $2)", ["public." <> table, name])

      reset_sequence(sequence, table, name)
    end)
  end

  defp reset_sequence(nil, _table, _column), do: :ok

  defp reset_sequence(sequence, table, column) do
    max = "(SELECT max(#{DataSet.quote_name(column)}) FROM #{DataSet.quote_name(table)})"

    Repo.query!("SELECT setval($1::text::regclass, COALESCE(#{max}, 1), #{max} IS NOT NULL)", [
      sequence
    ])
  end

  defp token, do: 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
