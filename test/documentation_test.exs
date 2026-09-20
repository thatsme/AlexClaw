defmodule AlexClaw.DocumentationTest do
  use ExUnit.Case, async: true
  @moduletag :docs

  # The skill API reference drifted from the code for six months: every function
  # in its examples had been renamed, and two of the permissions it listed did
  # not exist, so a skill written by following it was rejected at load. Nothing
  # failed, because nothing checked. These tests check.
  #
  # Run them alone with `mix test --only docs`.

  alias AlexClaw.Skills.SkillAPI

  @docs_root "docs"
  # Every tracked root document. The Dockerfile's test stage copies these by
  # name; a new one must be added in both places, and the corpus test says so.
  @root_docs ~w(
    ALEXCLAW_ARCHITECTURE.md CLA.md CODE_OF_CONDUCT.md CODING_CONVENTIONS.md
    CONTRIBUTING.md INSTALLATION.md README.md ROADMAP.md SECURITY.md
    SELF_AWARENESS.md
  )

  # A permission is named in prose as `:some_thing`. These suffixes are what
  # distinguishes a permission atom from `:ok`, `:error` or a skill's own atoms.
  @permission_shape ~r/`:([a-z_]+_(?:read|write|send|invoke|manage))`/
  @skill_api_call ~r/SkillAPI\.([a-z_]+[?!]?)(?![a-zA-Z0-9_?!])/
  @markdown_link ~r/\]\(([^)#:]+\.md)(?:#[^)]*)?\)/

  defp docs do
    Path.wildcard("#{@docs_root}/**/*.md") ++ @root_docs
  end

  defp read_all do
    Enum.map(docs(), &{&1, File.read!(&1)})
  end

  # Every check below scans files. A scan that finds no files passes trivially,
  # which is the failure mode these tests exist to prevent — so the corpus is
  # asserted first. The Dockerfile's test stage copies docs/ for this reason.
  test "the documentation corpus is present" do
    files = docs()

    assert length(files) > 20,
           "expected the docs tree, found #{length(files)} files — is docs/ missing from the test image?"

    assert Enum.any?(files, &String.starts_with?(&1, "docs/skills/"))

    missing = Enum.reject(@root_docs, &File.exists?/1)

    assert missing == [],
           "root documents missing from the test image — add them to the Dockerfile's test stage:\n  " <>
             Enum.join(missing, "\n  ")
  end

  test "every SkillAPI function named in the docs exists" do
    exported =
      SkillAPI.__info__(:functions)
      |> Enum.map(fn {name, _arity} -> Atom.to_string(name) end)
      |> MapSet.new()

    missing =
      for {file, body} <- read_all(),
          [_, name] <- Regex.scan(@skill_api_call, body),
          # `SkillAPI.http_*` is a deliberate wildcard in prose, not a call.
          not String.ends_with?(name, "_"),
          not MapSet.member?(exported, name),
          do: "#{file}: SkillAPI.#{name}"

    assert missing == [],
           "documented SkillAPI functions that do not exist:\n  " <>
             Enum.join(Enum.uniq(missing), "\n  ")
  end

  test "every permission atom named in the docs is a real permission" do
    known = MapSet.new(SkillAPI.known_permissions(), &Atom.to_string/1)

    invalid =
      for {file, body} <- read_all(),
          [_, atom] <- Regex.scan(@permission_shape, body),
          not MapSet.member?(known, atom),
          do: "#{file}: :#{atom}"

    assert invalid == [],
           "permissions named in the docs that a skill cannot declare:\n  " <>
             Enum.join(Enum.uniq(invalid), "\n  ")
  end

  test "every internal markdown link resolves" do
    broken =
      for {file, body} <- read_all(),
          [_, target] <- Regex.scan(@markdown_link, body),
          resolved = Path.expand(target, Path.dirname(file)),
          not File.exists?(resolved),
          do: "#{file} -> #{target}"

    assert broken == [],
           "links to files that do not exist:\n  " <> Enum.join(Enum.uniq(broken), "\n  ")
  end

  test "every mkdocs nav target exists" do
    nav = File.read!("mkdocs.yml")

    missing =
      for [_, target] <- Regex.scan(~r/:\s*([A-Za-z0-9_\-\/]+\.md)\s*$/m, nav),
          not File.exists?(Path.join(@docs_root, target)),
          do: target

    assert missing == [],
           "mkdocs.yml lists pages that do not exist:\n  " <> Enum.join(missing, "\n  ")
  end

  # The seeder no longer carries its own copy of the shell allowlist, and
  # seeded_keys_test guards that. The documented environment variables are the
  # same class of claim: a variable the code never reads is a setting that lies.
  test "every environment variable documented as required is read somewhere" do
    body = File.read!("docs/getting-started/configuration.md")

    documented =
      ~r/`([A-Z][A-Z0-9_]{3,})`/
      |> Regex.scan(body)
      |> Enum.map(fn [_, name] -> name end)
      |> Enum.uniq()

    sources =
      ["lib", "config"]
      |> Enum.flat_map(&Path.wildcard("#{&1}/**/*.{ex,exs}"))
      |> Enum.map_join("\n", &File.read!/1)

    unread = Enum.reject(documented, &String.contains?(sources, &1))

    assert unread == [],
           "documented as environment variables but never read in lib/ or config/:\n  " <>
             Enum.join(unread, "\n  ")
  end
end
