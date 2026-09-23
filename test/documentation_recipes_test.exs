defmodule AlexClaw.DocumentationRecipesTest do
  use ExUnit.Case, async: true
  @moduletag :docs

  # The recipe contract changed in 0.3.45, and the recipe examples in
  # INSTALLATION.md did not: the recorded example, the workflow example and the
  # "Supported Actions" table all showed the old shapes, and the table still
  # listed `evaluate` — so a recipe copied from the docs was refused
  # (doc-drift report, 2026-09-23). Rewriting the section fixes it once; these
  # tests keep it fixed. The contract is the code, and the docs are checked
  # against it the same way the shared fixtures are.
  #
  # Rules:
  # - every ```json block in the docs that is a recipe (`url` and `steps`) is
  #   accepted by Recipe.validate/1;
  # - every ```json block with `extra_steps` (a workflow step adding steps)
  #   has steps a recipe accepts;
  # - a table that lists actions (a heading containing "Supported Actions",
  #   first column a backticked name) lists exactly Recipe.actions/0.

  alias AlexClaw.WebAutomation.Recipe

  @root_docs ~w(INSTALLATION.md README.md SECURITY.md ALEXCLAW_ARCHITECTURE.md)

  defp docs, do: Path.wildcard("docs/**/*.md") ++ @root_docs

  defp json_blocks(text) do
    ~r/```json\n(.*?)```/s
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.map(fn [block] -> Jason.decode(block) end)
    |> Enum.flat_map(fn
      {:ok, map} when is_map(map) -> [map]
      _ -> []
    end)
  end

  defp recipe_blocks do
    for path <- docs(), block <- json_blocks(File.read!(path)), do: {path, block}
  end

  test "the docs show recipes at all (no vacuous pass)" do
    assert Enum.any?(recipe_blocks(), fn {_path, block} ->
             Map.has_key?(block, "steps") or Map.has_key?(block, "extra_steps")
           end),
           "no ```json recipe block found in the docs: the checks below would compare nothing"
  end

  test "every recipe in the docs is one the contract accepts" do
    refused =
      for {path, block} <- recipe_blocks(),
          Map.has_key?(block, "url") and Map.has_key?(block, "steps"),
          {:error, reasons} <- [Recipe.validate(block)],
          do: "#{path}: #{Enum.join(reasons, "; ")}"

    assert refused == [],
           "recipes in the docs the contract refuses:\n  " <> Enum.join(refused, "\n  ")
  end

  test "every extra_steps example in the docs uses contract steps" do
    refused =
      for {path, %{"extra_steps" => steps}} <- recipe_blocks(),
          {:error, reasons} <- [
            Recipe.validate(%{"url" => "https://example.com", "steps" => steps})
          ],
          do: "#{path}: #{Enum.join(reasons, "; ")}"

    assert refused == [],
           "extra_steps in the docs the contract refuses:\n  " <> Enum.join(refused, "\n  ")
  end

  test "every table of supported actions lists exactly the contract's actions" do
    tables =
      for path <- docs(),
          table <- action_tables(File.read!(path)),
          do: {path, table}

    assert tables != [], "no \"Supported Actions\" table found in the docs"

    for {path, listed} <- tables do
      expected = MapSet.new(Recipe.actions())
      listed = MapSet.new(listed)

      assert listed == expected,
             "#{path}: missing #{inspect(MapSet.difference(expected, listed) |> MapSet.to_list())}, " <>
               "extra #{inspect(MapSet.difference(listed, expected) |> MapSet.to_list())}"
    end
  end

  # The rows of each table under a heading that contains "Supported Actions":
  # the first cell, when it is a single backticked name.
  defp action_tables(text) do
    text
    |> String.split(~r/^#+ .*Supported Actions.*$/m)
    |> Enum.drop(1)
    |> Enum.map(fn section ->
      section
      |> String.split("\n")
      |> Enum.drop_while(&(not String.starts_with?(&1, "|")))
      |> Enum.take_while(&String.starts_with?(&1, "|"))
      |> Enum.flat_map(fn row ->
        case Regex.run(~r/^\|\s*`([a-z_]+)`\s*\|/, row) do
          [_, action] -> [action]
          nil -> []
        end
      end)
    end)
  end
end
