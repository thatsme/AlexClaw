defmodule AlexClaw.DocsContractTest do
  @moduledoc """
  The public docs cannot drift from the code: what they name must exist, and
  what they list must match what the code has. The repo is public, so a code
  change that makes a doc false fails the build here.

  - every `make` target, script and repo path named in a public doc exists;
  - README's skills table is the core skills in `SkillRegistry`, both ways
    (rows marked "(dynamic)" are dynamic skills and exempt);
  - README's Admin UI table covers every live route in the router;
  - the injection-pattern count a doc states is the count in the source;
  - every internal Markdown link, and its anchor, resolves.

  Settings and environment variables documented, and removed names absent,
  are checked by `DocumentationTest` and `DocsRemovedNamesTest`.

  Public docs: the top-level README, SECURITY, INSTALLATION, CONTRIBUTING and
  ROADMAP, every page under docs/, and the release notes of the version in
  mix.exs (older notes describe their own release).
  """
  use ExUnit.Case, async: true
  @moduletag :docs

  alias AlexClaw.Workflows.SkillRegistry

  @top ~w(README.md SECURITY.md INSTALLATION.md CONTRIBUTING.md ROADMAP.md)

  # Names that look like repo paths and are not: example names in how-to text;
  # the unseal key, created by the operator on the host and kept out of every
  # image; MCP resource names.
  @not_paths ~w(test/a_test.exs test/b_test.exs openbao/unseal openbao/unseal/key config/list)

  # The admin pages reached from another page, documented under it.
  @subpages %{"WorkflowRuns" => "Workflows"}

  defp docs do
    version = :alex_claw |> Application.spec(:vsn) |> to_string() |> String.split("+") |> hd()
    @top ++ Path.wildcard("docs/**/*.md") ++ [".github/release-notes/v#{version}.md"]
  end

  defp read(doc), do: File.read!(doc)

  defp numbered_lines(doc),
    do: doc |> read() |> String.split("\n") |> Enum.with_index(1)

  # Code a doc shows: inline `code` and fenced blocks, with their line.
  defp code(doc) do
    {spans, _fenced} =
      doc
      |> numbered_lines()
      |> Enum.flat_map_reduce(false, fn {line, n}, fenced ->
        cond do
          String.starts_with?(String.trim_leading(line), "```") -> {[], not fenced}
          fenced -> {[{line, n}], true}
          true -> {Enum.map(Regex.scan(~r/`([^`]+)`/, line), &{List.last(&1), n}), false}
        end
      end)

    spans
  end

  defp make_targets do
    ~r/^([A-Za-z0-9_.-]+):/m
    |> Regex.scan(File.read!("Makefile"))
    |> MapSet.new(&List.last/1)
  end

  test "every make target a doc names exists" do
    targets = make_targets()

    missing =
      for doc <- docs(),
          {text, n} <- code(doc),
          [_, target] <- Regex.scan(~r/(?:^|[;&|]\s*|\$\s+)make\s+([a-z][a-z0-9_-]*)/, text),
          not MapSet.member?(targets, target),
          do: "#{doc}:#{n}: make #{target}"

    assert missing == [], "make targets that do not exist:\n" <> Enum.join(missing, "\n")
  end

  # A path up to a placeholder (`v<version>.md`) is checked up to its directory.
  @path ~r{(?<![\w./-])((?:scripts|lib|test|config|docs|priv|demo|openbao|db-init|web-automator|\.github)/[\w./-]*[\w]|docker-compose[\w.-]*\.yml|\.env\.example)(?![<{])}

  test "every script and repo path a doc names exists" do
    missing =
      for doc <- docs(),
          {text, n} <- code(doc),
          [_, path] <- Regex.scan(@path, text),
          path not in @not_paths,
          not File.exists?(path),
          do: "#{doc}:#{n}: #{path}"

    assert missing == [], "paths that do not exist:\n" <> Enum.join(missing, "\n")
  end

  # The rows of the first table after `heading` in README: {first cell, row}.
  defp readme_table(heading) do
    "README.md"
    |> read()
    |> String.split(heading, parts: 2)
    |> List.last()
    |> String.split("\n")
    |> Enum.drop_while(&(not String.starts_with?(&1, "|")))
    |> Enum.take_while(&String.starts_with?(&1, "|"))
    |> Enum.drop(2)
    |> Enum.map(fn row -> {row |> String.split("|") |> Enum.at(1) |> String.trim(), row} end)
  end

  test "README's skills table is the core skills, both ways" do
    documented =
      for {cell, row} <- readme_table("### Skills"),
          not String.contains?(row, "(dynamic)"),
          into: MapSet.new(),
          do: String.trim(cell, "`")

    core =
      for {name, _module, :core, _perms, _routes, _ext} <- SkillRegistry.list_all_with_type(),
          into: MapSet.new(),
          do: name

    assert MapSet.difference(core, documented) |> Enum.sort() == [],
           "core skills missing from README's skills table (left)"

    assert MapSet.difference(documented, core) |> Enum.sort() == [],
           "README lists skills that are not core skills (left)"
  end

  # The admin pages (AlexClawWeb.AdminLive.*); the LiveDashboard's routes are
  # Phoenix's own.
  test "README's Admin UI table covers every live route" do
    pages = MapSet.new(readme_table("## Admin UI"), &elem(&1, 0))

    missing =
      for %{metadata: %{phoenix_live_view: {module, _action, _opts, _extra}}, path: path} <-
            Phoenix.Router.routes(AlexClawWeb.Router),
          match?(["AlexClawWeb", "AdminLive" | _], Module.split(module)),
          page = module |> Module.split() |> List.last(),
          page = Map.get(@subpages, page, page),
          not MapSet.member?(pages, page),
          do: "#{path} (#{page})"

    assert missing == [], "live routes missing from README's Admin UI table: #{inspect(missing)}"
  end

  test "the injection-pattern count a doc states is the source's" do
    count =
      "priv/injection_patterns.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("patterns")
      |> length()

    wrong =
      for doc <- docs(),
          {line, n} <- numbered_lines(doc),
          line =~ ~r/inject|Garak/i,
          [_, stated] <-
            Regex.scan(~r/\b(\d+)\s+(?:known\s+)?(?:injection\s+)?(?:patterns|phrases)\b/, line),
          String.to_integer(stated) != count,
          do: "#{doc}:#{n}: #{stated} (the source has #{count})"

    assert wrong == [], "injection-pattern counts that disagree:\n" <> Enum.join(wrong, "\n")
  end

  @link ~r/\[[^\]]*\]\(([^)\s]+)\)/
  @blob "https://github.com/thatsme/AlexClaw/blob/main/"

  test "every internal link and anchor resolves" do
    broken =
      for doc <- docs(),
          {line, n} <- numbered_lines(doc),
          [_, target] <- Regex.scan(@link, line),
          reason = unresolved(doc, target),
          reason != nil,
          do: "#{doc}:#{n}: #{target} — #{reason}"

    assert broken == [], "links that do not resolve:\n" <> Enum.join(broken, "\n")
  end

  defp unresolved(doc, @blob <> rest), do: resolved(rest)
  defp unresolved(_doc, "http" <> _external), do: nil
  defp unresolved(_doc, "mailto:" <> _), do: nil
  defp unresolved(doc, "#" <> anchor), do: anchored(doc, anchor)

  defp unresolved(doc, target) do
    doc
    |> Path.dirname()
    |> Path.join(target)
    |> Path.expand()
    |> Path.relative_to_cwd()
    |> resolved()
  end

  defp resolved(target) do
    case String.split(target, "#", parts: 2) do
      [path] -> exists(path)
      [path, anchor] -> exists(path) || anchored(path, anchor)
    end
  end

  defp exists(path), do: if(File.exists?(path), do: nil, else: "no such file")

  defp anchored(path, anchor) do
    if File.dir?(path) or not String.ends_with?(path, ".md") or anchor in anchors(path),
      do: nil,
      else: "no heading for ##{anchor}"
  end

  # Headings as GitHub and MkDocs make anchors of them.
  defp anchors(path) do
    for line <- path |> read() |> String.split("\n"),
        [_, title] <- [Regex.run(~r/^#+\s+(.+?)\s*#*$/, line)],
        slug <- slugs(title),
        do: slug
  end

  defp slugs(title) do
    plain = title |> String.replace(~r/[`*_~]/, "") |> String.downcase()
    github = plain |> String.replace(~r/[^\p{L}\p{N}\s_-]/u, "") |> String.replace(" ", "-")

    mkdocs =
      plain
      |> String.replace(~r/[^\w\s-]/u, "")
      |> String.trim()
      |> String.replace(~r/[-\s]+/, "-")

    Enum.uniq([github, mkdocs])
  end
end
