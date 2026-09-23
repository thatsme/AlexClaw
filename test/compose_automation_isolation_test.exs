defmodule AlexClaw.ComposeAutomationIsolationTest do
  @moduledoc """
  Web automator, phase 1 (reports/WEB_AUTOMATOR_TARGET.md §1.1; F4, F5).

  The sidecar runs a browser on pages AlexClaw does not control. It was on
  the default network with Postgres, reachable from any container there.

  - F4: no automation service shares a network with the database.
  - F5: the sidecar's API port (6900) is never published, and every port any
    service publishes binds to 127.0.0.1 **by default** — a bare "6080:6080"
    binds to every interface on the host.

  "By default": a mapping may take its bind address from a variable, as
  `${ADMIN_BIND:-127.0.0.1}` does for serving the admin UI to a reverse proxy.
  The test resolves `${VAR:-default}` and `${VAR-default}` to the default, so
  the file as shipped binds loopback, and anything else is the operator's
  explicit choice. A variable with no default resolves to "" and fails: an
  unset variable must never mean every interface.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  @files ~w(docker-compose.yml docker-compose_swarm.yml docker-compose.test.yml)
  @automation ~w(web-automator web-studio)
  @databases ~w(db-prod db db-test)

  defp services(file), do: file |> YamlElixir.read_from_file!() |> Map.fetch!("services")

  # A service with no networks key is on the project's "default" network.
  defp networks(service) do
    case service["networks"] do
      nil -> ["default"]
      list when is_list(list) -> list
      map when is_map(map) -> Map.keys(map)
    end
  end

  defp ports(service), do: Enum.map(service["ports"] || [], &port/1)

  defp port(%{"published" => published} = long),
    do: {defaults(long["host_ip"]), defaults(published), defaults(long["target"])}

  defp port(short), do: short |> defaults() |> String.split(":") |> split_port()

  # ${VAR:-default} and ${VAR-default} → default; ${VAR} → "".
  defp defaults(nil), do: ""

  defp defaults(value) do
    value
    |> to_string()
    |> then(&Regex.replace(~r/\$\{\w+:?-([^}]*)\}/, &1, "\\1"))
    |> then(&Regex.replace(~r/\$\{\w+\}/, &1, ""))
  end

  # The last two parts are host port and container port; whatever precedes
  # them is the bind address (IPv6 addresses contain colons).
  defp split_port([target]), do: {"", "", target}
  defp split_port([host, target]), do: {"", host, target}

  defp split_port(parts) do
    {ip_parts, [host, target]} = Enum.split(parts, -2)
    {Enum.join(ip_parts, ":"), host, target}
  end

  test "defaults are resolved the way docker compose resolves them" do
    assert port("${ADMIN_BIND:-127.0.0.1}:${ADMIN_PORT:-5001}:5001") ==
             {"127.0.0.1", "5001", "5001"}

    assert port("${ADMIN_BIND-127.0.0.1}:5002:5001") == {"127.0.0.1", "5002", "5001"}
    assert port("${ADMIN_BIND}:5001:5001") == {"", "5001", "5001"}
    assert port("6080:6080") == {"", "6080", "6080"}
  end

  # Guards against a vacuous pass: if the service names drift, the checks
  # above would compare nothing.
  test "docker-compose.yml has the services these checks are about" do
    names = Map.keys(services("docker-compose.yml"))
    assert "web-automator" in names
    assert "db-prod" in names
  end

  for file <- @files do
    test "#{file}: no automation service shares a network with a database" do
      services = services(unquote(file))

      for {name, service} <- services,
          name in @automation,
          {db, db_service} <- services,
          db in @databases do
        shared =
          MapSet.intersection(MapSet.new(networks(service)), MapSet.new(networks(db_service)))

        assert MapSet.size(shared) == 0,
               "#{name} shares #{inspect(MapSet.to_list(shared))} with #{db}"
      end
    end

    test "#{file}: the sidecar API port 6900 is never published" do
      for {name, service} <- services(unquote(file)), {_ip, host, target} <- ports(service) do
        refute "6900" in [host, target] and host != "",
               "#{name} publishes 6900"
      end
    end

    test "#{file}: every published port binds to 127.0.0.1" do
      for {name, service} <- services(unquote(file)),
          {ip, host, _target} <- ports(service),
          host != "" do
        assert ip == "127.0.0.1",
               "#{name} publishes #{host} on #{if ip == "", do: "every interface", else: ip}"
      end
    end
  end
end
