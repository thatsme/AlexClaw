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

    # The deployment reads some variables itself: the database owner's
    # credentials reach only the migrate service, through the compose files,
    # and the mix aliases that migrate the test database.
    deployment = ["mix.exs" | Path.wildcard("docker-compose*.yml")] ++ Path.wildcard("db-init/*")

    sources =
      ["lib", "config"]
      |> Enum.flat_map(&Path.wildcard("#{&1}/**/*.{ex,exs}"))
      |> Kernel.++(deployment)
      |> Enum.map_join("\n", &File.read!/1)

    unread = Enum.reject(documented, &String.contains?(sources, &1))

    assert unread == [],
           "documented as environment variables but never read in lib/, config/ or the deployment files:\n  " <>
             Enum.join(unread, "\n  ")
  end

  # The supervision tree drifted in both directions and in two documents at
  # once: five live children were missing, one was named as the process it
  # starts rather than the supervised child, and the condition guarding the
  # last two was described as an environment variable nothing reads.
  test "the documented supervision tree matches application.ex" do
    page = File.read!("docs/architecture/supervision-tree.md")
    app = File.read!("lib/alex_claw/application.ex")

    # Only the branch lines of the diagram: the root label and the prose below
    # it name modules that are not children.
    documented =
      page
      |> String.split("\n")
      |> Enum.filter(&String.contains?(&1, ["├──", "└──"]))
      |> Enum.join("\n")
      |> module_names()
      |> MapSet.new()

    {unconditional, conditional} = application_children(app)
    actual = MapSet.union(unconditional, conditional)

    assert MapSet.difference(actual, documented) |> MapSet.to_list() == [],
           "children started in application.ex but absent from the page: " <>
             inspect(MapSet.difference(actual, documented) |> MapSet.to_list())

    assert MapSet.difference(documented, actual) |> MapSet.to_list() == [],
           "children on the page that application.ex does not start: " <>
             inspect(MapSet.difference(documented, actual) |> MapSet.to_list())

    # A conditional child described as unconditional is the error that was there
    # before, so each one must be named under the condition that guards it.
    guarded = page |> String.split(":start_background_workers", parts: 2) |> List.last()

    for child <- conditional do
      assert String.contains?(guarded, child),
             "#{child} starts only when :start_background_workers is true — say so on the page"
    end
  end

  defp module_names(text) do
    ~r/\b(AlexClaw(?:Web)?(?:\.[A-Z][A-Za-z0-9_]*)+)/
    |> Regex.scan(text)
    |> Enum.map(fn [_, name] -> name end)
    |> Enum.uniq()
  end

  # Children listed directly, and those returned by background_children/1.
  defp application_children(app) do
    [_, main] = Regex.run(~r/children = \[(.+?)\n    \]/s, app)
    background = Regex.run(~r/defp background_children\(true\) do\n\s*\[(.+?)\]/s, app)

    {MapSet.new(module_names(main)),
     MapSet.new(if(background, do: module_names(Enum.at(background, 1)), else: []))}
  end

  # A category named in the docs must be one the seeder writes. One-way on
  # purpose: the seeder also uses `skill.*` prefixes as key namespaces rather
  # than UI groupings, and the docs should not have to mirror that.
  test "every config category named in the docs exists in the seeder" do
    seeded = seeded_categories()

    named =
      for {file, body} <- read_all(),
          [_, category] <- Regex.scan(~r/`([a-z_]+)`\s*\|[^|\n]*(?:categor|setting)/i, body),
          uniq: true,
          do: {file, category}

    invalid = for {file, c} <- named, not MapSet.member?(seeded, c), do: "#{file}: #{c}"

    assert invalid == [],
           "config categories named in the docs that the seeder never writes:\n  " <>
             Enum.join(Enum.uniq(invalid), "\n  ")
  end

  # The seeder's categories, plus the schema default that any setting created
  # without one falls into.
  defp seeded_categories do
    "lib/alex_claw/config/seeder.ex"
    |> File.read!()
    |> String.split("@defaults [", parts: 2)
    |> List.last()
    |> String.split("\n  @env_mapping", parts: 2)
    |> List.first()
    |> then(&Regex.scan(~r/"[a-z0-9_.]+",[^}]*?"[a-z]+",\s*"([a-z_.]+)"/s, &1))
    |> Enum.map(&List.last/1)
    |> MapSet.new()
    |> MapSet.put("general")
  end

  # A cheap lint rather than a guarantee: module names were the one thing that
  # had not drifted, so this catches a typo, not a design problem.
  # AlexClaw.TaskSupervisor and friends are registered process names started by
  # something else — real addresses, but not modules anyone defines.
  @registered_names ~w(
    AlexClaw.TaskSupervisor AlexClaw.PubSub AlexClaw.Supervisor
    AlexClaw.CircuitBreakerRegistry
  )

  test "every module named in the docs is defined in lib/ or is a registered name" do
    defined =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.flat_map(fn f ->
        ~r/^\s*defmodule\s+([A-Za-z0-9_.]+)/m
        |> Regex.scan(File.read!(f))
        |> Enum.map(&List.last/1)
      end)
      |> MapSet.new()

    unknown =
      for {file, body} <- read_all(),
          name <- module_names(body),
          name not in @registered_names,
          not MapSet.member?(defined, name),
          not placeholder?(name, defined),
          do: "#{file}: #{name}"

    assert unknown == [],
           "modules named in the docs that lib/ does not define:\n  " <>
             Enum.join(Enum.uniq(unknown), "\n  ")
  end

  # Names that are not meant to resolve: a skill the operator writes, a
  # namespace prefix, or a placeholder in a teaching example.
  defp placeholder?(name, defined) do
    String.starts_with?(name, "AlexClaw.Skills.Dynamic") or
      String.ends_with?(name, ["MySkill", "YourSkill", "Example"]) or
      Enum.any?(defined, &String.starts_with?(&1, name <> "."))
  end
end
