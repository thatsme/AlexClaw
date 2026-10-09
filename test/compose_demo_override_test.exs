defmodule AlexClaw.ComposeDemoOverrideTest do
  @moduledoc """
  Production's AlexClaw never joins the demo database's network
  (reports/SQLREAD_ATTACKER_REVIEW.md L8). It joins it only when the demo is
  started with its own compose file, `docker-compose.demo.yml`, given on top
  of `docker-compose.yml`; a plain `docker compose up -d` leaves AlexClaw on
  its own networks.

  The demo network's subnet is AlexClaw's alone: it overlaps neither
  production's other networks nor the test stack's, so the demo and the test
  stack can run side by side.
  """
  use ExUnit.Case, async: true
  @moduletag :docs

  defp read(file), do: YamlElixir.read_from_file!(file)

  defp networks(service) do
    case service["networks"] do
      list when is_list(list) -> list
      map when is_map(map) -> Map.keys(map)
      nil -> ["default"]
    end
  end

  defp subnets(file) do
    for {_name, network} <- read(file)["networks"] || %{},
        config <- get_in(network, ["ipam", "config"]) || [],
        do: config["subnet"]
  end

  test "in docker-compose.yml no service but the demo database is on the demo network" do
    on_demo =
      for {name, svc} <- read("docker-compose.yml")["services"], "demo" in networks(svc), do: name

    assert on_demo == ["demo-db"]
  end

  test "docker-compose.demo.yml adds AlexClaw to the demo network at a pinned address, and nothing else" do
    override = read("docker-compose.demo.yml")

    assert Map.keys(override["services"]) == ["alexclaw-prod"]
    assert Map.keys(override["services"]["alexclaw-prod"]) == ["networks"]

    assert %{"demo" => %{"ipv4_address" => address}} =
             override["services"]["alexclaw-prod"]["networks"]

    assert is_binary(address)
  end

  test "the demo subnet overlaps no other network of production or of the test stack" do
    [demo] =
      for {"demo", network} <- read("docker-compose.yml")["networks"],
          config <- network["ipam"]["config"],
          do: config["subnet"]

    others = (subnets("docker-compose.yml") -- [demo]) ++ subnets("docker-compose.test.yml")
    refute demo in others
  end
end
