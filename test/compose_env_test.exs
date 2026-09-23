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

  Two kinds of exception, each named with its reason:
  - @migrate_only: read only by `AlexClaw.Release` in the one-shot `migrate`
    service — it must be passed THERE, and the test checks that it is;
  - @not_passed: never set by an operator at all.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  @sources ["config/runtime.exs" | Path.wildcard("lib/**/*.ex")]
  @env_functions [:get_env, :fetch_env, :fetch_env!]

  # Read only by AlexClaw.Release's migration step, which runs in `migrate`.
  @migrate_only %{
    "DATABASE_APP_USERNAME" =>
      "the migration grants the application role its privileges; the app itself connects as that role and never reads the name"
  }

  # Read by the application but never set by an operator.
  @not_passed %{
    "RELEASE_COMMAND" =>
      "set by the release start script (start, eval, remote); an operator never sets it"
  }

  defp environment(service) do
    "docker-compose.yml"
    |> YamlElixir.read_from_file!()
    |> get_in(["services", service, "environment"])
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

  defp names, do: reads() |> Enum.map(&elem(&1, 0)) |> MapSet.new()

  # Guards the scan itself: if it found nothing it knows is read, the
  # assertion below would pass on an empty list.
  test "the scan finds variables known to be read" do
    names = names()
    assert "SECRET_KEY_BASE" in names or "DATABASE_HOSTNAME" in names
    assert "GOOGLE_OAUTH_CLIENT_ID" in names, "the seeder's @env_mapping was not scanned"
  end

  test "every variable the application reads is passed to alexclaw-prod" do
    passed = environment("alexclaw-prod")

    missing =
      reads()
      |> Enum.reject(fn {name, _where} ->
        name in passed or Map.has_key?(@not_passed, name) or Map.has_key?(@migrate_only, name)
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.sort()

    assert missing == [],
           "read but not passed to alexclaw-prod in docker-compose.yml:\n" <>
             Enum.map_join(missing, "\n", fn {name, where} ->
               "  #{name} (#{Enum.join(where, ", ")})"
             end)
  end

  test "every migrate-only variable is passed to migrate" do
    passed = environment("migrate")

    for name <- Map.keys(@migrate_only) do
      assert name in passed, "#{name} is read by the migration but not passed to migrate"
    end
  end

  test "every exception has a reason and is still read by the code" do
    names = names()

    for {name, reason} <- Map.merge(@not_passed, @migrate_only) do
      assert is_binary(reason) and String.length(reason) > 20, "#{name} has no reason"
      assert name in names, "#{name} is no longer read by the code — drop its exception"
    end
  end
end
