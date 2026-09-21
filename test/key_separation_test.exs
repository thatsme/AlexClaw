defmodule AlexClaw.KeySeparationTest do
  # System.put_env and Application.put_env are global.
  use ExUnit.Case, async: false
  @moduletag :docs

  @moduledoc """
  The database owner's credentials and SECRET_KEY_BASE never share a
  container. Together they are everything needed to read every stored
  secret and rewrite the schema; apart, a compromise of either container
  gives half.

  The migrate service therefore runs without the key, which the runtime
  configuration allows for an `eval` and nothing else.
  """

  @compose_files ~w(docker-compose.yml docker-compose_swarm.yml)

  defp runtime_config(env) do
    env = Map.put_new(env, "CLUSTER_COOKIE", "Zm9vYmFyYmF6cXV4")
    original = Enum.map(env, fn {k, _v} -> {k, System.get_env(k)} end)
    Enum.each(env, fn {k, v} -> put(k, v) end)

    try do
      "config/runtime.exs"
      |> Config.Reader.read!(env: :prod)
      |> get_in([:alex_claw, AlexClawWeb.Endpoint, :secret_key_base])
    after
      Enum.each(original, fn {k, v} -> put(k, v) end)
    end
  end

  defp put(key, nil), do: System.delete_env(key)
  defp put(key, value), do: System.put_env(key, value)

  defp references?(service, variable) do
    service
    |> Map.get("environment", %{})
    |> Map.values()
    |> Enum.any?(&(is_binary(&1) and String.contains?(&1, "${#{variable}")))
  end

  test "no compose service is given both the owner's password and SECRET_KEY_BASE" do
    for file <- @compose_files,
        {name, service} <- YamlElixir.read_from_file!(file)["services"] do
      refute references?(service, "DATABASE_OWNER_PASSWORD") and
               references?(service, "SECRET_KEY_BASE"),
             "#{file}: #{name} holds the owner's password and SECRET_KEY_BASE"
    end
  end

  test "the migrate service connects as the owner and has no SECRET_KEY_BASE" do
    for file <- @compose_files do
      migrate = YamlElixir.read_from_file!(file)["services"]["migrate"]
      assert references?(migrate, "DATABASE_OWNER_PASSWORD")
      refute references?(migrate, "SECRET_KEY_BASE"), "#{file}: migrate has the key"
    end
  end

  describe "the runtime configuration without SECRET_KEY_BASE" do
    test "is accepted for an eval, with no key configured" do
      assert runtime_config(%{"SECRET_KEY_BASE" => nil, "RELEASE_COMMAND" => "eval"}) == nil
      assert runtime_config(%{"SECRET_KEY_BASE" => "", "RELEASE_COMMAND" => "eval"}) == nil
    end

    test "is refused for every other command" do
      for command <- ["start", "daemon", "rpc", nil] do
        assert_raise RuntimeError, ~r/SECRET_KEY_BASE not set/, fn ->
          runtime_config(%{"SECRET_KEY_BASE" => nil, "RELEASE_COMMAND" => command})
        end
      end
    end

    test "an eval given the key still uses it" do
      key = String.duplicate("k", 64)
      assert runtime_config(%{"SECRET_KEY_BASE" => key, "RELEASE_COMMAND" => "eval"}) == key
    end
  end
end
