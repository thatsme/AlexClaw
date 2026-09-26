defmodule AlexClaw.ComposeProfilesTest do
  @moduledoc """
  The web-automator is opt-in: a plain `docker compose up -d` neither builds
  nor starts it (a large Playwright image, for an experimental feature), and
  nothing that does start depends on it.
  """
  use ExUnit.Case, async: true
  @moduletag :docs

  defp services, do: YamlElixir.read_from_file!("docker-compose.yml")["services"]

  test "the web-automator runs only under the web-automation profile" do
    assert services()["web-automator"]["profiles"] == ["web-automation"]
  end

  test "every other service starts by default, and none depends on the web-automator" do
    for {name, service} <- services(), name not in ["web-automator", "openbao-backup"] do
      refute Map.has_key?(service, "profiles"), "#{name} would not start by default"

      depends = service |> Map.get("depends_on", %{}) |> dependency_names()
      refute "web-automator" in depends, "#{name} depends on an opt-in service"
    end
  end

  test "the documented command names the profile that exists" do
    assert File.read!("INSTALLATION.md") =~ "docker compose --profile web-automation up -d"
    refute File.read!("INSTALLATION.md") =~ "--profile web-automator"
  end

  defp dependency_names(depends) when is_map(depends), do: Map.keys(depends)
  defp dependency_names(depends) when is_list(depends), do: depends
end
