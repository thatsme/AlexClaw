defmodule AlexClaw.ComposeEnvTest do
  @moduledoc """
  Every environment variable the application reads is passed to the
  `alexclaw-prod` service in `docker-compose.yml`. The compose file has no
  `env_file:`, so a variable set in `.env` reaches the container only if the
  service's `environment:` names it; one that is read but not passed is
  silently unset in production (as `GOOGLE_OAUTH_*` were until 0.3.47).

  "Read" means a literal name given to `System.get_env/1,2`,
  `System.fetch_env/1` or `System.fetch_env!/1` in `lib/` or
  `config/runtime.exs`, plus the names in `Config.Seeder`'s `@env_mapping`,
  which the seeder reads through a variable.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  @sources ["config/runtime.exs" | Path.wildcard("lib/**/*.ex")]
  @env_functions [:get_env, :fetch_env, :fetch_env!]

  # Read by the application but deliberately not passed to alexclaw-prod,
  # each with the reason.
  @not_passed %{}

  defp passed do
    "docker-compose.yml"
    |> YamlElixir.read_from_file!()
    |> get_in(["services", "alexclaw-prod", "environment"])
    |> Map.keys()
  end

  defp reads do
    for path <- @sources,
        {name, line} <- reads_in(path),
        do: {name, "#{path}:#{line}"}
  end

  defp reads_in(path) do
    {_ast, found} =
      path
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], &collect/2)

    found
  end

  defp collect({{:., meta, [{:__aliases__, _, [:System]}, fun]}, _, [name | _]} = node, acc)
       when fun in @env_functions and is_binary(name),
       do: {node, [{name, meta[:line]} | acc]}

  defp collect({:@, meta, [{:env_mapping, _, [{:%{}, _, pairs}]}]} = node, acc),
    do: {node, for({_key, {name, _default}} <- pairs, do: {name, meta[:line]}) ++ acc}

  defp collect(node, acc), do: {node, acc}

  # Guards the scan itself: if it found nothing it knows is read, the
  # assertion below would pass on an empty list.
  test "the scan finds variables known to be read" do
    names = reads() |> Enum.map(&elem(&1, 0))
    assert "SECRET_KEY_BASE" in names or "DATABASE_HOSTNAME" in names
    assert "GOOGLE_OAUTH_CLIENT_ID" in names, "the seeder's @env_mapping was not scanned"
  end

  test "every variable the application reads is passed to alexclaw-prod" do
    passed = passed()

    missing =
      reads()
      |> Enum.reject(fn {name, _where} -> name in passed or Map.has_key?(@not_passed, name) end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.sort()

    assert missing == [],
           "read but not passed to alexclaw-prod in docker-compose.yml:\n" <>
             Enum.map_join(missing, "\n", fn {name, where} ->
               "  #{name} (#{Enum.join(where, ", ")})"
             end)
  end
end
