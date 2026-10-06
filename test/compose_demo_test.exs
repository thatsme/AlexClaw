defmodule AlexClaw.ComposeDemoTest do
  @moduledoc """
  The demo database (reports/SQL_READ_PREMISES.md §4.4): a PostgreSQL with
  generated company data for showing `sql_query`, opt-in and kept apart.

  - It runs only under the `demo` profile; a plain `docker compose up -d`
    neither starts it nor needs its variable.
  - It is on its own internal network, shared with AlexClaw alone, and
    publishes no port.
  - It runs with as little as possible: not root, no capabilities, no
    privilege gain, a read-only root; its data lives in a tmpfs and is
    generated again at every start, so nothing persists.
  - Its image is pinned by digest.
  - Its pg_hba admits one thing from the network: the read-only role, from
    AlexClaw's pinned address, with scram-sha-256.
  - The read-only role's password comes from `DEMO_READER_PASSWORD`, with no
    default, and is entered in the connection form like any other.
  """
  use ExUnit.Case, async: true
  @moduletag :docs

  defp compose, do: YamlElixir.read_from_file!("docker-compose.yml")
  defp service(name), do: compose()["services"][name]

  defp networks(service) do
    case service["networks"] do
      list when is_list(list) -> list
      map when is_map(map) -> Map.keys(map)
      nil -> ["default"]
    end
  end

  defp hba_rules do
    "demo/pg_hba.conf"
    |> File.read!()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.map(&String.split/1)
  end

  test "it is on the demo network only, which is internal and shared with AlexClaw alone" do
    assert networks(service("demo-db")) == ["demo"]
    assert compose()["networks"]["demo"]["internal"] == true

    override = YamlElixir.read_from_file!("docker-compose.demo.yml")["services"]

    on_demo =
      for {name, svc} <- Map.merge(compose()["services"], override),
          "demo" in networks(svc),
          do: name

    assert Enum.sort(on_demo) == ["alexclaw-prod", "demo-db"]
  end

  test "it publishes no port" do
    refute Map.has_key?(service("demo-db"), "ports")
    refute Map.has_key?(service("demo-db"), "expose")
  end

  test "it runs with as little as possible" do
    svc = service("demo-db")
    refute to_string(svc["user"] || "") in ["", "0", "root", "0:0", "root:root"]
    assert "ALL" in List.wrap(svc["cap_drop"])
    assert "no-new-privileges:true" in List.wrap(svc["security_opt"])
    assert svc["read_only"] == true

    mounts = svc["tmpfs"] |> List.wrap() |> Enum.map(&(&1 |> String.split(":") |> hd()))
    assert "/tmp" in mounts
    assert "/var/lib/postgresql/data" in mounts, "its data must not persist"

    refute Map.has_key?(svc, "volumes") and
             Enum.any?(svc["volumes"], &(&1 =~ ~r{:/var/lib/postgresql}))
  end

  test "its image is pinned by digest" do
    assert service("demo-db")["image"] =~ ~r/^postgres:17[-\w.]*@sha256:[0-9a-f]{64}$/
  end

  test "pg_hba admits only the read-only role, from AlexClaw's address, with scram" do
    alexclaw =
      YamlElixir.read_from_file!("docker-compose.demo.yml")["services"]["alexclaw-prod"][
        "networks"
      ]["demo"]["ipv4_address"]

    assert is_binary(alexclaw)

    host_rules = Enum.filter(hba_rules(), &(hd(&1) in ~w(host hostssl hostnossl)))
    admitted = Enum.reject(host_rules, &(List.last(&1) == "reject"))

    assert admitted == [["host", "demo", "alexclaw_reader", alexclaw <> "/32", "scram-sha-256"]]
    assert ["host", "all", "all", "0.0.0.0/0", "reject"] in host_rules
    assert ["host", "all", "all", "::/0", "reject"] in host_rules
    refute Enum.any?(hba_rules(), &(hd(&1) != "local" and List.last(&1) == "trust"))
  end

  test "the read-only role's password has no default, and a plain start does not need it" do
    env = service("demo-db")["environment"]
    assert env["DEMO_READER_PASSWORD"] == "${DEMO_READER_PASSWORD:-}"
    assert File.read!(".env.example") =~ ~r/^# DEMO_READER_PASSWORD=$/m
    assert File.read!("demo/initdb/03-reader.sh") =~ "DEMO_READER_PASSWORD"
  end
end
