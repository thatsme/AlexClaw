defmodule AlexClaw.Config.SeededKeysTest do
  use ExUnit.Case, async: true

  # A setting that lies is worse than a missing one: every seeded key is a
  # control in Admin > Config that promises an effect. These two tests read the
  # source tree and fail when a key is seeded with no reader, or read with no
  # seed — the two directions the same bug has already appeared in.

  @seeder "lib/alex_claw/config/seeder.ex"

  # Built at runtime from the skill name: Config.get("prompts.context.#{skill}").
  @dynamically_read ~w(
    prompts.context.rss
    prompts.context.research
    prompts.context.conversational
  )

  # Keys with a reader but deliberately no seed.
  #   auth.totp.pending_secret — written by TOTP.setup/0, deleted on confirm
  #   rss_feeds                — legacy key the resource migrator reads once
  #                              and deletes; seeding it would resurrect it
  #   mcp.api_key              — absent means MCP is unauthenticated and denied
  #   auth.totp.last_used_at   — written on the first accepted code, and kept
  #                              out of the config cache with the secret
  @unseeded_by_design ~w(
    auth.totp.pending_secret
    rss_feeds
    mcp.api_key
    auth.totp.last_used_at
  )

  @read_calls ~r/(?:Config\.get|Config\.enabled\?|config_get|config_int|config_or_default|configured_list)\(\s*"([a-z0-9_.]+)"/

  defp seeded_keys do
    @seeder
    |> File.read!()
    |> String.split("@defaults [", parts: 2)
    |> List.last()
    |> String.split("\n  @env_mapping", parts: 2)
    |> List.first()
    |> then(&Regex.scan(~r/\{"([a-z0-9_.]+)",/, &1))
    |> Enum.map(&List.last/1)
  end

  defp lib_sources do
    Path.wildcard("lib/**/*.{ex,heex}") -- [@seeder]
  end

  test "every seeded key has a reader in lib/" do
    source = Enum.map_join(lib_sources(), "\n", &File.read!/1)

    # Both tests are source scans: an empty scan would pass vacuously.
    assert length(seeded_keys()) > 50
    assert String.contains?(source, "Config.get(")

    unread =
      Enum.reject(seeded_keys(), fn key ->
        key in @dynamically_read or String.contains?(source, ~s("#{key}"))
      end)

    assert unread == [],
           "seeded but never read: #{inspect(unread)} — wire each one or remove key, seed and UI entry"
  end

  test "every key read in lib/ is seeded" do
    read =
      lib_sources()
      |> Enum.flat_map(&Regex.scan(@read_calls, File.read!(&1)))
      |> Enum.map(&List.last/1)
      |> Enum.uniq()

    seeded = seeded_keys()

    unseeded =
      Enum.reject(read, &(&1 in seeded or &1 in @unseeded_by_design))

    assert unseeded == [],
           "read but never seeded: #{inspect(unseeded)} — these silently use a hardcoded default and have no UI entry"
  end
end
