defmodule AlexClaw.ComposeOriginTest do
  @moduledoc """
  Every application container learns the port its admin UI is published on,
  and the operator's origin settings. Without them `config/runtime.exs` can
  only guess :5001, and a UI published anywhere else renders with every
  button dead.
  """
  use ExUnit.Case, async: true
  @moduletag :docs

  @files ~w(docker-compose.yml docker-compose_swarm.yml)

  # The containers that serve the admin UI: the ones publishing port 5001.
  defp app_services(file) do
    file
    |> YamlElixir.read_from_file!()
    |> Map.fetch!("services")
    |> Enum.filter(fn {_name, s} -> Enum.any?(Map.get(s, "ports", []), &published_ui?/1) end)
  end

  defp published_ui?(mapping), do: String.ends_with?(mapping, ":5001")

  # "${ADMIN_BIND:-127.0.0.1}:5002:5001" -> "5002"
  defp host_port(service) do
    [mapping] = Enum.filter(service["ports"], &published_ui?/1)
    [_, port] = Regex.run(~r/(\$\{[^}]+\}|\d+):5001$/, mapping)
    port
  end

  test "every compose file has an application container" do
    for file <- @files, do: assert(app_services(file) != [], "#{file} publishes no admin UI")
  end

  test "each application container is told the port it is published on" do
    for file <- @files, {name, service} <- app_services(file) do
      assert service["environment"]["ADMIN_PORT"] == host_port(service),
             "#{file}: #{name} publishes #{host_port(service)} but is told " <>
               "ADMIN_PORT=#{inspect(service["environment"]["ADMIN_PORT"])}"
    end
  end

  test "each application container receives PHX_HOST and CHECK_ORIGIN" do
    for file <- @files, {name, service} <- app_services(file), var <- ~w(PHX_HOST CHECK_ORIGIN) do
      assert service["environment"][var] == "${#{var}:-}", "#{file}: #{name} does not pass #{var}"
    end
  end
end
