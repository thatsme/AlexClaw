defmodule AlexClaw.MixProject do
  use Mix.Project

  @version "0.3.36"

  def project do
    [
      app: :alex_claw,
      version: @version <> build_suffix(),
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger],
      included_applications: [:nostrum],
      mod: {AlexClaw.Application, []}
    ]
  end

  defp deps do
    [
      {:phoenix, "~> 1.7"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_live_reload, "~> 1.5", only: :dev},
      {:phoenix_live_dashboard, "~> 0.8"},
      {:bandit, "~> 1.6"},
      {:ecto_sql, "~> 3.11"},
      {:postgrex, ">= 0.0.0"},
      {:pgvector, "~> 0.3"},
      {:req, "~> 0.5"},
      {:sweet_xml, "~> 0.7"},
      {:quantum, "~> 3.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:floki, "~> 0.37"},
      {:nimble_totp, "~> 1.0"},
      {:eqrcode, "~> 0.1"},
      {:nostrum, "~> 0.10"},
      {:certifi, "~> 2.12"},
      {:gun, "~> 2.0", override: true},
      {:tz, "~> 0.28"},
      {:timex, "~> 3.7"},
      {:csv, "~> 3.2"},
      {:yaml_elixir, "~> 2.11"},
      {:anubis_mcp, "~> 1.0"},
      {:mox, "~> 1.2", only: :test},
      {:bypass, "~> 2.1", only: :test},
      # Required by Phoenix.LiveViewTest to parse rendered markup.
      {:lazy_html, ">= 0.1.0", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      # app.config first: the ecto tasks load configuration themselves, which
      # would otherwise overwrite the owner's credentials; a task already run
      # is not run again.
      "ecto.create": ["app.config", &as_owner/1, "ecto.create"],
      "ecto.migrate": ["app.config", &as_owner/1, "ecto.migrate", &grant_app_role/1]
    ]
  end

  # The application role cannot create databases or run DDL. Where the owner's
  # credentials are given (DATABASE_OWNER_USERNAME/_PASSWORD, as the test stack
  # does), creating and migrating switch to them, and migrating ends by granting
  # the application role its privileges — the same step a release's migrate
  # runs. Without them nothing changes, so a single-role setup keeps working.
  defp as_owner(_args), do: switch_to_owner(System.get_env("DATABASE_OWNER_USERNAME"))

  defp switch_to_owner(nil), do: :ok

  defp switch_to_owner(owner) do
    config = Application.get_env(:alex_claw, AlexClaw.Repo, [])
    System.put_env("DATABASE_APP_USERNAME", Keyword.fetch!(config, :username))

    Application.put_env(
      :alex_claw,
      AlexClaw.Repo,
      Keyword.merge(config,
        username: owner,
        password: System.fetch_env!("DATABASE_OWNER_PASSWORD")
      )
    )
  end

  defp grant_app_role(_args), do: grant_app_role(System.get_env("DATABASE_OWNER_USERNAME"), :run)

  defp grant_app_role(nil, :run), do: :ok

  defp grant_app_role(_owner, :run) do
    {:ok, _} = Application.ensure_all_started(:postgrex)
    config = Application.fetch_env!(:alex_claw, AlexClaw.Repo)

    {:ok, conn} =
      config
      |> Keyword.take([:hostname, :port, :username, :password, :database])
      |> Postgrex.start_link()

    apply(AlexClaw.Database.Roles, :grant, [conn, System.fetch_env!("DATABASE_APP_USERNAME")])
    GenServer.stop(conn)
  end

  defp build_suffix do
    case System.cmd("git", ["rev-list", "--count", "HEAD"], stderr_to_stdout: true) do
      {count, 0} ->
        "+build.#{String.trim(count)}"

      _ ->
        case System.get_env("BUILD_NUMBER") do
          nil -> ""
          "0" -> ""
          n -> "+build.#{n}"
        end
    end
  end
end
