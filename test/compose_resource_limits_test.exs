defmodule AlexClaw.ComposeResourceLimitsTest do
  @moduledoc """
  Every long-running AlexClaw container has a memory and CPU ceiling, in both
  compose files, so it can never take the host down. Local model servers run
  on the host outside these limits; the limits bound AlexClaw itself.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  @limited %{
    "docker-compose.yml" => ~w(alexclaw-prod web-automator),
    "docker-compose_swarm.yml" => ~w(node1 node2)
  }

  defp services(file), do: file |> YamlElixir.read_from_file!() |> Map.fetch!("services")

  for {file, names} <- @limited, name <- names do
    test "#{file}: #{name} declares mem_limit and cpus" do
      service = Map.fetch!(services(unquote(file)), unquote(name))

      assert is_binary(service["mem_limit"]) and service["mem_limit"] != "",
             "#{unquote(name)} has no mem_limit"

      assert is_number(service["cpus"]) and service["cpus"] > 0,
             "#{unquote(name)} has no cpus limit"
    end
  end
end
