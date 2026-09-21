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

  @doc """
  Grant `role` exactly the application's privileges. Run as the owner.

  The role name is interpolated, since SQL cannot bind an identifier, so it is
  checked against a plain identifier pattern first and refused otherwise.
  """
  @spec grant(DBConnection.conn(), String.t()) :: :ok
  def grant(conn, role) do
    role |> identifier!() |> statements() |> Enum.each(&Postgrex.query!(conn, &1, []))
  end

  defp statements(role) do
    [
      "GRANT USAGE ON SCHEMA public TO #{role}",
      "GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES IN SCHEMA public TO #{role}",
      "REVOKE UPDATE, DELETE, TRUNCATE ON auth_audit_log FROM #{role}",
      "REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON schema_migrations FROM #{role}",
      "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO #{role}",
      "GRANT EXECUTE ON FUNCTION prune_auth_audit_log() TO #{role}"
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

    %{rows: owned} =
      Postgrex.query!(conn, "SELECT tablename FROM pg_tables WHERE tableowner = current_user", [])

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
