defmodule AlexClaw.MixProject do
  use Mix.Project

  @version "0.2.2"

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
      {:tz, "~> 0.28"},
      {:mox, "~> 1.2", only: :test},
      {:bypass, "~> 2.1", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"]
    ]
  end

  defp build_suffix do
    case System.cmd("git", ["rev-list", "--count", "HEAD"], stderr_to_stdout: true) do
      {count, 0} -> "+build.#{String.trim(count)}"
      _ ->
        case System.get_env("BUILD_NUMBER") do
          nil -> ""
          "0" -> ""
          n -> "+build.#{n}"
        end
    end
  end
end
