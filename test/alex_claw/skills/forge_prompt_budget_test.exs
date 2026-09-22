defmodule AlexClaw.Skills.ForgePromptBudgetTest do
  @moduledoc """
  Forge's prompt fits the provider it is sent to: knowledge-base chunks are
  kept in priority order while they fit, whole or not at all, and a mandatory
  part larger than the budget is an explicit error rather than a cut prompt.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  alias AlexClaw.LLM.Window
  alias AlexClaw.Skills.CodeGenerator

  @chunks [
    "TEMPLATE " <> String.duplicate("t", 3000),
    "EXAMPLE " <> String.duplicate("e", 3000),
    "DOCS " <> String.duplicate("d", 3000)
  ]

  defp mandatory, do: Window.estimate(CodeGenerator.build_prompt("a clock", "clock", "", nil))

  test "with room for everything, every chunk is in" do
    assert {:ok, prompt} = CodeGenerator.fitted_prompt("a clock", "clock", @chunks, nil, 100_000)
    for c <- ["TEMPLATE", "EXAMPLE", "DOCS"], do: assert(prompt =~ c)
  end

  test "with room for some, the highest-priority chunks are kept, whole" do
    room_for_two = mandatory() + 2 * (Window.estimate(hd(@chunks)) + 2) + 10

    assert {:ok, prompt} =
             CodeGenerator.fitted_prompt("a clock", "clock", @chunks, nil, room_for_two)

    assert prompt =~ "TEMPLATE"
    assert prompt =~ "EXAMPLE"
    refute prompt =~ "DOCS"
    assert prompt =~ String.duplicate("e", 3000), "a chunk is never cut"
    assert prompt =~ "module name must be AlexClaw.Skills.Dynamic.Clock"
    assert Window.estimate(prompt) <= room_for_two
  end

  test "with room only for the mandatory part, no chunk is in" do
    assert {:ok, prompt} =
             CodeGenerator.fitted_prompt("a clock", "clock", @chunks, nil, mandatory())

    refute prompt =~ "TEMPLATE"
    assert prompt =~ "a clock"
  end

  test "a mandatory part larger than the budget is refused" do
    assert {:error, {:does_not_fit, tokens}} =
             CodeGenerator.fitted_prompt("a clock", "clock", @chunks, nil, mandatory() - 1)

    assert tokens == mandatory()
  end

  test "an unknown window gets everything, as before" do
    assert {:ok, prompt} =
             CodeGenerator.fitted_prompt("a clock", "clock", @chunks, nil, :unlimited)

    assert prompt =~ "DOCS"
  end

  test "no chunks at all is just the mandatory part" do
    assert {:ok, _} = CodeGenerator.fitted_prompt("a clock", "clock", [], nil, mandatory())
  end

  describe "a repair prompt" do
    @code "defmodule AlexClaw.Skills.Dynamic.Clock do\n  def run(_), do: DateTime.to_iso8601_string(DateTime.utc_now())\nend"

    test "carries the failing code, its error and the module name" do
      prompt = CodeGenerator.repair_prompt("a clock", "clock", @code, "undefined function")

      assert prompt =~ @code
      assert prompt =~ "undefined function"
      assert prompt =~ "module name must be AlexClaw.Skills.Dynamic.Clock"
    end

    test "is bounded by the code, whatever the size of the error or the goal" do
      huge = String.duplicate("x", 200_000)
      prompt = CodeGenerator.repair_prompt(huge, "clock", @code, huge)
      small = CodeGenerator.repair_prompt("", "clock", @code, "")

      # Goal and error are capped at 2,000 characters each.
      assert byte_size(prompt) <= byte_size(small) + 4_000
    end

    test "an empty error still names what to fix" do
      prompt = CodeGenerator.repair_prompt("a clock", "clock", @code, "")
      assert prompt =~ @code
    end
  end
end
