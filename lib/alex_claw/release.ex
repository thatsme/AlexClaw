defmodule AlexClaw.Release do
  @moduledoc """
  Release tasks for running migrations and seeding in production.
  Called from entrypoint.sh before the app starts.
  """
  @app :alex_claw

  @spec migrate() :: [{:ok, [integer()], [Ecto.Migration.t()]}]
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @spec seed_examples() :: [{:ok, any(), any()}]
  def seed_examples do
    load_app()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn _repo ->
          if AlexClaw.Workflows.list_workflows() == [] do
            seed_path = Application.app_dir(@app, "priv/repo/seeds/example_workflows.exs")

            if File.exists?(seed_path) do
              IO.puts("First boot detected — seeding example workflows...")
              Code.eval_file(seed_path)
            end
          else
            IO.puts("Workflows already exist — skipping seed.")
          end
        end)
    end
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
