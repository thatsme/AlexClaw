defmodule AlexClaw.Release do
  @moduledoc """
  Release tasks for running migrations and seeding in production.
  Called from entrypoint.sh before the app starts.
  """
  alias AlexClaw.Config.{Rekey, Undecryptable}
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

  @doc """
  Re-encrypt the stored secrets for a new SECRET_KEY_BASE — see
  `AlexClaw.Config.Rekey`. With the application stopped, and with
  OLD_SECRET_KEY_BASE and the new SECRET_KEY_BASE both in the environment.
  """
  @spec rekey() :: :ok
  def rekey do
    old = old_secret_key_base!()
    load_app()
    new = System.fetch_env!("SECRET_KEY_BASE")

    for repo <- repos() do
      {:ok, result, _} =
        Ecto.Migrator.with_repo(repo, fn _repo -> Rekey.run(old, new) end)

      report_rekey(result)
    end

    :ok
  end

  @missing_old_key "OLD_SECRET_KEY_BASE is not set: a rotation needs the current key there " <>
                     "and the new one in SECRET_KEY_BASE"

  @doc """
  The current key for a rotation, from OLD_SECRET_KEY_BASE — the one place it
  is read. Compose passes the variable as an empty string outside a rotation,
  so unset, empty and whitespace-only all raise, naming the variable.
  """
  @spec old_secret_key_base!() :: String.t()
  def old_secret_key_base! do
    value = System.get_env("OLD_SECRET_KEY_BASE", "")
    if String.trim(value) == "", do: raise(@missing_old_key), else: value
  end

  defp report_rekey({:ok, count}),
    do: IO.puts("Re-encrypted #{count} values under the new SECRET_KEY_BASE.")

  defp report_rekey({:error, reason}), do: raise("SECRET_KEY_BASE rotation refused: #{reason}")

  @doc """
  For a SECRET_KEY_BASE lost for good, with the application stopped: lists the
  stored values that do not decrypt under the current key, and discards
  nothing. `discard_undecryptable/1` with the confirmation printed here clears
  exactly those values. See "Lost key" in docs/deployment/rotate-secret-key-base.md.
  """
  @spec discard_undecryptable() :: :ok
  def discard_undecryptable do
    load_app()

    for repo <- repos() do
      {:ok, entries, _} = Ecto.Migrator.with_repo(repo, fn _repo -> Undecryptable.list() end)
      report_undecryptable(entries)
    end

    :ok
  end

  @doc "Clear the values `discard_undecryptable/0` listed, given its confirmation."
  @spec discard_undecryptable(String.t()) :: :ok
  def discard_undecryptable(confirmation) do
    load_app()

    for repo <- repos() do
      {:ok, result, _} =
        Ecto.Migrator.with_repo(repo, fn _repo -> Undecryptable.discard(confirmation) end)

      report_discard(result)
    end

    :ok
  end

  defp report_undecryptable([]),
    do: IO.puts("Every stored value decrypts under this SECRET_KEY_BASE. Nothing to discard.")

  defp report_undecryptable(entries) do
    IO.puts("These #{length(entries)} stored values do not decrypt under this SECRET_KEY_BASE:")
    Enum.each(entries, &IO.puts("  " <> Undecryptable.describe(&1)))

    IO.puts("""

    Nothing was changed. If the previous SECRET_KEY_BASE is lost for good, discard them with:
      AlexClaw.Release.discard_undecryptable("#{Undecryptable.confirmation(entries)}")
    """)
  end

  defp report_discard({:ok, entries}),
    do: IO.puts("Discarded #{length(entries)} undecryptable values; the audit log names them.")

  defp report_discard({:error, reason}), do: raise("Nothing was discarded: #{reason}")

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
