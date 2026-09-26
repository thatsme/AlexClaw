defmodule AlexClaw.Release do
  @moduledoc """
  Release tasks for running migrations and seeding in production.
  Called from entrypoint.sh before the app starts.
  """
  alias AlexClaw.Auth.SecondFactor
  alias AlexClaw.Database.Roles

  @app :alex_claw

  @doc """
  Run every pending migration, then grant the application role its privileges.

  Runs as the database owner — in production the one-shot `migrate` service,
  which is the only container given the owner's credentials. The role to grant
  is `DATABASE_APP_USERNAME`; without it there is no separate application role
  to grant, and the step says so.
  """
  @spec migrate() :: [:ok]
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
      grant_app_role(repo, System.get_env("DATABASE_APP_USERNAME"))
    end
  end

  defp grant_app_role(_repo, nil) do
    IO.puts("DATABASE_APP_USERNAME is not set — no application role to grant.")
  end

  defp grant_app_role(repo, role) do
    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, conn} = Postgrex.start_link(connection_opts(repo))

    try do
      Roles.grant(conn, role)
      IO.puts("Granted #{role} the application's privileges.")
    after
      GenServer.stop(conn)
    end
  end

  defp connection_opts(repo) do
    Keyword.take(repo.config(), [:hostname, :port, :username, :password, :database, :ssl])
  end

  @spec seed_examples() :: [{:ok, any(), any()}]
  def seed_examples do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, fn _repo -> seed_if_empty() end)
    end
  end

  defp seed_if_empty do
    seed_if_empty(AlexClaw.Workflows.list_workflows() == [])
  end

  defp seed_if_empty(false), do: IO.puts("Workflows already exist — skipping seed.")

  defp seed_if_empty(true) do
    seed_path = Application.app_dir(@app, "priv/repo/seeds/example_workflows.exs")
    eval_seed(seed_path, File.exists?(seed_path))
  end

  defp eval_seed(_seed_path, false), do: :ok

  defp eval_seed(seed_path, true) do
    IO.puts("First boot detected — seeding example workflows...")
    Code.eval_file(seed_path)
  end

  @doc """
  Turn the admin's second factor off, for when the authenticator and every
  recovery code are lost: `make reset-2fa` (scripts/reset-2fa.sh) runs this
  inside the running node (`bin/alex_claw rpc`). 2FA off, its key deleted in
  OpenBao, every recovery code removed, an audit row written; then a
  warning. Anyone who can run it already has a shell on the host.
  """
  @spec reset_second_factor() :: :ok | {:error, term()}
  def reset_second_factor, do: reset_said(SecondFactor.impl().reset())

  defp reset_said(:ok) do
    IO.puts("""
    WARNING: the second factor is off. The admin's authenticator key was
    deleted from OpenBao and every recovery code was removed.
    Until 2FA is set up again (Services page), the admin UI is read-only and
    nothing that needs a code can run. The reset is recorded in the audit log.
    """)
  end

  defp reset_said({:error, reason} = error) do
    IO.puts("The second factor was NOT reset: #{inspect(reason)}. Nothing was changed.")
    error
  end

  @spec rollback(module(), integer()) :: {:ok, [integer()], [Ecto.Migration.t()]}
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
