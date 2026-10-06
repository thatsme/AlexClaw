defmodule AlexClaw.BuildContextSecretsTest do
  @moduledoc """
  No image is built with a secret in it (2026-10-06: production's OpenBao
  unseal key was found in the local test image — the test stage copies
  `openbao/`, and nothing kept `openbao/unseal/` out of the build context).

  Every build context the compose files name has a `.dockerignore` that
  keeps out the secret and private paths under it: OpenBao's unseal key, the
  `.env` file, backups and snapshots, the test stack's OpenBao credentials,
  crash dumps, and the private working files. A new build context fails here
  until it is listed with its own exclusions.

  And inside the test stack — an image built from this context — the unseal
  key and the `.env` file do not exist.
  """
  use ExUnit.Case, async: true
  @moduletag :docs

  @compose_files ~w(docker-compose.yml docker-compose.test.yml docker-compose_swarm.yml)

  # context => the paths under it that must never reach a build.
  @contexts %{
    "." => [
      "openbao/unseal",
      ".env",
      "backups",
      "openbao-backups",
      ".openbao-test",
      "local-docs",
      "reports",
      "erl_crash.dump",
      "*.dump",
      "*.snap",
      ".claude",
      "CLAUDE.md"
    ],
    "./openbao" => ["unseal"],
    "./web-automator" => [".env"]
  }

  defp contexts do
    for file <- @compose_files,
        File.exists?(file),
        {_name, service} <- YamlElixir.read_from_file!(file)["services"],
        build = service["build"],
        build != nil,
        uniq: true,
        do: context(build)
  end

  defp context(%{"context" => context}), do: normalised(context)
  defp context(context) when is_binary(context), do: normalised(context)

  defp normalised("."), do: "."
  defp normalised("./" <> _ = path), do: String.trim_trailing(path, "/")
  defp normalised(path), do: "./" <> String.trim_trailing(path, "/")

  defp ignored(context) do
    context
    |> Path.join(".dockerignore")
    |> File.read!()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.map(&String.trim_trailing(&1, "/"))
  end

  test "every build context is one whose exclusions are listed here" do
    assert Enum.sort(contexts()) -- Map.keys(@contexts) == []
  end

  for {context, paths} <- @contexts do
    test "#{context}/.dockerignore keeps the secret paths out of the build" do
      ignored = ignored(unquote(context))

      for path <- unquote(paths) do
        assert path in ignored, "#{unquote(context)}/.dockerignore does not exclude #{path}"
      end
    end
  end

  test ".env.example still reaches the image the tests read it from" do
    refute ".env*" in ignored(".")
    refute ".env.example" in ignored(".")
  end

  describe "inside the test stack" do
    @describetag :integration

    test "the image holds no unseal key and no .env" do
      refute File.exists?("openbao/unseal/key")
      refute File.dir?("openbao/unseal")
      refute File.exists?(".env")
      assert File.exists?("openbao/config.hcl"), "the scan would be vacuous: openbao/ is not here"
    end
  end
end
