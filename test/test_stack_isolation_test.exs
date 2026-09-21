defmodule AlexClaw.TestStackIsolationTest do
  @moduledoc """
  The test stack can run beside production: it is its own compose project, it
  publishes no host ports, and it names no container, network or volume that
  production uses. Its teardown (`docker compose ... down`) therefore reaches
  nothing of production's, and its database cannot collide on a port.

  These properties are what allow the suite to run while production is up.
  Each test here guards one of them.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  @test_file "docker-compose.test.yml"
  @production_files ~w(docker-compose.yml docker-compose_swarm.yml)

  defp compose(path), do: YamlElixir.read_from_file!(path)

  defp services(file), do: file |> compose() |> Map.fetch!("services")

  defp container_names(file) do
    file
    |> services()
    |> Map.values()
    |> Enum.map(& &1["container_name"])
    |> Enum.reject(&is_nil/1)
  end

  # A compose file without `name:` takes its project name from the directory,
  # which is the production project's name.
  test "the test stack is its own compose project" do
    assert compose(@test_file)["name"] == "alexclaw-test"

    for file <- @production_files do
      refute compose(file)["name"] == "alexclaw-test", "#{file} claims the test project"
    end
  end

  test "no test service publishes a host port" do
    published =
      for {name, service} <- services(@test_file),
          Map.has_key?(service, "ports"),
          do: name

    assert published == []
  end

  test "no test container shares a name with a production container" do
    production = Enum.flat_map(@production_files, &container_names/1)
    assert container_names(@test_file) -- production == container_names(@test_file)
  end

  # Only bind mounts: a named volume would belong to the test project, but
  # an `external` one could be production's.
  test "the test stack declares no named volume" do
    assert compose(@test_file)["volumes"] in [nil, %{}]

    named =
      for {_name, service} <- services(@test_file),
          mount <- Map.get(service, "volumes", []),
          not String.starts_with?(mount, "."),
          do: mount

    assert named == []
  end
end
