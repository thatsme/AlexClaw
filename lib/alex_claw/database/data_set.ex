defmodule AlexClaw.Database.DataSet do
  @moduledoc """
  What an export holds and a restore replaces, read from the live catalog.

  The application's data is every table except three: the audit log, which is
  append-only and never replaced; the logins, which belong to whoever is signed
  in now; and the migrator's bookkeeping. Table names, column names and column
  types all come from the database's own catalog. A restore file supplies
  values and nothing else — no name, type or statement of it is ever used.
  """

  alias AlexClaw.Database.Roles
  alias AlexClaw.Repo

  @excluded ~w(auth_audit_log admin_sessions schema_migrations)

  @doc "The tables an export holds, parents before the tables that reference them."
  @spec tables() :: [String.t()]
  def tables do
    tables = Map.keys(Roles.privileges()) -- @excluded
    ordered(tables, dependencies(tables), [])
  end

  @doc "Tables never exported and never replaced by a restore."
  @spec excluded() :: [String.t()]
  def excluded, do: @excluded

  @doc "`[{name, type}]` for `table`, in column order."
  @spec columns(String.t()) :: [{String.t(), String.t()}]
  def columns(table) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT a.attname, format_type(a.atttypid, a.atttypmod)
        FROM pg_attribute a
        JOIN pg_class c ON a.attrelid = c.oid
        JOIN pg_namespace n ON c.relnamespace = n.oid
        WHERE n.nspname = 'public' AND c.relname = $1 AND a.attnum > 0 AND NOT a.attisdropped
        ORDER BY a.attnum
        """,
        [table]
      )

    Enum.map(rows, fn [name, type] -> {name, type} end)
  end

  @doc "The primary key columns of `table`."
  @spec primary_key(String.t()) :: [String.t()]
  def primary_key(table) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT a.attname
        FROM pg_index i
        JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
        WHERE i.indrelid = ('public.' || quote_ident($1))::regclass AND i.indisprimary
        """,
        [table]
      )

    List.flatten(rows)
  end

  @doc "The latest migration applied — an export restores only onto the same schema."
  @spec schema_version() :: integer()
  def schema_version do
    %{rows: [[version]]} = Repo.query!("SELECT max(version) FROM schema_migrations")
    version
  end

  @doc "`name` quoted as an SQL identifier."
  @spec quote_name(String.t()) :: String.t()
  def quote_name(name), do: ~s(") <> String.replace(name, ~s("), ~s("")) <> ~s(")

  # table => the other exported tables it references
  defp dependencies(tables) do
    %{rows: rows} =
      Repo.query!("""
      SELECT child.relname, parent.relname
      FROM pg_constraint co
      JOIN pg_class child ON co.conrelid = child.oid
      JOIN pg_class parent ON co.confrelid = parent.oid
      WHERE co.contype = 'f' AND child.relnamespace = 'public'::regnamespace
      """)

    Enum.reduce(rows, Map.new(tables, &{&1, []}), fn [child, parent], acc ->
      add_dependency(acc, child, parent, child != parent and parent in tables)
    end)
  end

  defp add_dependency(acc, child, parent, true),
    do: Map.update(acc, child, [parent], &[parent | &1])

  defp add_dependency(acc, _child, _parent, false), do: acc

  # Parents first. Sorted within each round so the order is stable.
  defp ordered(remaining, _dependencies, done) when remaining == [], do: Enum.reverse(done)

  defp ordered(remaining, dependencies, done) do
    ready =
      remaining
      |> Enum.filter(fn table -> Enum.all?(dependencies[table], &(&1 in done)) end)
      |> Enum.sort()

    ordered(remaining -- ready, dependencies, Enum.reverse(ready) ++ done)
  end
end
