defmodule AlexClaw.Database.Roles do
  @moduledoc """
  Two database roles, and what each may do.

  The **owner** owns the schema. It runs migrations and full backups, and it
  never serves the application. The **application role** is what the running
  app connects as: it owns nothing, cannot create roles or databases, and is
  not a superuser. On `auth_audit_log` it may read and insert, never update,
  delete or truncate — old rows leave only through `prune_auth_audit_log()`,
  a function owned by the owner that deletes nothing younger than thirty days.

  `grant/2` states those privileges, as the owner, after every migration, so a
  table added later is covered without a migration of its own. `check/1`
  confirms, as the application, that the connection it was given is the
  restricted one — see `AlexClaw.Database.PrivilegeCheck`.

  Both take a Postgrex connection of their own rather than the Repo: they run
  before the application's pool exists, and in tests beside a sandboxed one.
  """

  @identifier ~r/\A[a-z_][a-z0-9_]{0,62}\z/

  @full ~w(SELECT INSERT UPDATE DELETE TRUNCATE)

  # One decision per table. A table added by a migration and missing here fails
  # the grant step, and the test that compares this map with the schema.
  @privileges %{
    # Append-only: rows leave only through prune_auth_audit_log().
    "auth_audit_log" => ~w(SELECT INSERT),
    # The migrator's bookkeeping; the application only reads it.
    "schema_migrations" => ~w(SELECT),
    "admin_sessions" => @full,
    "auth_policies" => @full,
    "auth_recovery_codes" => @full,
    "cluster_nodes" => @full,
    "dynamic_skills" => @full,
    "knowledge_entries" => @full,
    "llm_providers" => @full,
    "llm_usage" => @full,
    "memories" => @full,
    "reasoning_sessions" => @full,
    "reasoning_steps" => @full,
    "resources" => @full,
    "settings" => @full,
    "skill_outcomes" => @full,
    "workflow_resources" => @full,
    "workflow_runs" => @full,
    "workflow_steps" => @full,
    "workflows" => @full
  }

  @doc """
  Grant `role` exactly the application's privileges. Run as the owner.

  Every table gets the privileges `privileges/0` names for it and nothing more:
  each is revoked in full and then granted, so a broader grant made by hand is
  not left behind. A table the map has no decision for fails the step — a table
  nobody decided about is not granted by default.

  The role name is interpolated, since SQL cannot bind an identifier, so it is
  checked against a plain identifier pattern first and refused otherwise.
  """
  @spec grant(DBConnection.conn(), String.t()) :: :ok
  def grant(conn, role) do
    role = identifier!(role)
    :ok = decided!(tables(conn))

    ["GRANT USAGE ON SCHEMA public TO #{role}"]
    |> Kernel.++(
      Enum.flat_map(@privileges, fn {table, privileges} ->
        table_grants(table, privileges, role)
      end)
    )
    |> Kernel.++([
      "GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO #{role}",
      "GRANT EXECUTE ON FUNCTION prune_auth_audit_log() TO #{role}"
    ])
    |> Enum.each(&Postgrex.query!(conn, &1, []))
  end

  @doc """
  What the application role may do to each table. Every table in the schema
  has an entry, by decision: see the test that fails the build when one is
  missing.
  """
  @spec privileges() :: %{String.t() => [String.t()]}
  def privileges, do: @privileges

  @doc "The tables in the schema, as the connection sees them."
  @spec tables(DBConnection.conn()) :: [String.t()]
  def tables(conn) do
    %{rows: rows} =
      Postgrex.query!(conn, "SELECT tablename FROM pg_tables WHERE schemaname = 'public'", [])

    List.flatten(rows)
  end

  defp decided!(tables) do
    case tables -- Map.keys(@privileges) do
      [] ->
        :ok

      undecided ->
        raise ArgumentError, "no privilege decision for tables: #{Enum.join(undecided, ", ")}"
    end
  end

  defp table_grants(table, [], role), do: ["REVOKE ALL ON #{table} FROM #{role}"]

  defp table_grants(table, privileges, role) do
    [
      "REVOKE ALL ON #{table} FROM #{role}",
      "GRANT #{Enum.join(privileges, ", ")} ON #{table} TO #{role}"
    ]
  end

  @doc """
  Whether the connection's own role is the restricted one. Answers `:ok`, or
  every way it is not.
  """
  @spec check(DBConnection.conn()) :: :ok | {:error, [String.t()]}
  def check(conn) do
    %{rows: [[name, super?, createrole?, createdb?, bypassrls?]]} =
      Postgrex.query!(
        conn,
        "SELECT rolname, rolsuper, rolcreaterole, rolcreatedb, rolbypassrls " <>
          "FROM pg_roles WHERE rolname = current_user",
        []
      )

    # The bootstrap superuser also owns PostgreSQL's own catalogs; those are
    # not the application's tables and would bury the ones that are.
    %{rows: owned} =
      Postgrex.query!(
        conn,
        "SELECT tablename FROM pg_tables WHERE tableowner = current_user " <>
          "AND schemaname NOT IN ('pg_catalog', 'information_schema') ORDER BY tablename",
        []
      )

    [
      super? && "#{name} is a superuser",
      createrole? && "#{name} can create roles",
      createdb? && "#{name} can create databases",
      bypassrls? && "#{name} bypasses row-level security",
      owned != [] && "#{name} owns tables: #{owned |> List.flatten() |> Enum.join(", ")}"
    ]
    |> Enum.filter(& &1)
    |> checked()
  end

  defp checked([]), do: :ok
  defp checked(problems), do: {:error, problems}

  defp identifier!(role) when is_binary(role) do
    if Regex.match?(@identifier, role),
      do: role,
      else: raise(ArgumentError, "#{inspect(role)} is not a plain role name")
  end
end
