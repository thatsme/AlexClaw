defmodule AlexClaw.Database.PrivilegeCheck do
  @moduledoc """
  Refuse to start on a database connection with more power than the
  application needs.

  The application connects as its own role: not a superuser, unable to create
  roles or databases, not exempt from row-level security, and owner of no
  table — see `AlexClaw.Database.Roles`. An instance configured with the
  owner's credentials instead would run, and would quietly have every power
  the role separation exists to take away: rewriting the audit log among them.
  So in production it does not run. The boot stops before any child starts,
  naming each privilege the connection should not have.

  Enforced in production, where `config/runtime.exs` sets it unconditionally;
  there is no variable to turn it off. A development or test setup that uses
  one role for everything is unaffected.
  """

  alias AlexClaw.Database.Roles

  @doc "Check the configured connection, when enforcement is on. Raises otherwise."
  @spec run!() :: :ok
  def run!, do: run!(Application.get_env(:alex_claw, :enforce_db_privileges, false))

  @doc false
  @spec run!(boolean()) :: :ok
  def run!(false), do: :ok

  def run!(true) do
    {:ok, _} = Application.ensure_all_started(:postgrex)

    {:ok, conn} =
      :alex_claw
      |> Application.fetch_env!(AlexClaw.Repo)
      |> Keyword.take([:hostname, :port, :username, :password, :database, :ssl])
      |> Postgrex.start_link()

    try do
      check!(conn)
    after
      GenServer.stop(conn)
    end
  end

  @doc "Raise, naming every problem, unless `conn` is the restricted application role."
  @spec check!(DBConnection.conn()) :: :ok
  def check!(conn), do: conn |> Roles.check() |> checked!()

  defp checked!(:ok), do: :ok

  defp checked!({:error, problems}) do
    raise RuntimeError, """
    AlexClaw will not start on this database connection:

      #{Enum.join(problems, "\n  ")}

    DATABASE_USERNAME must be the application role, not the database owner. The
    owner's credentials belong to the migrate service only (DATABASE_OWNER_*).
    See docs/deployment/upgrade-0.3.34.md.
    """
  end
end
