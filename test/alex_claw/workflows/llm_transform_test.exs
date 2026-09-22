defmodule AlexClaw.Workflows.LLMTransformTest do
  @moduledoc """
  A transform step either transforms or fails, and its prompt is built for the
  provider it is sent to. A step with no template used to return its input
  unchanged; a long diff used to be cut by the model's server, or refused.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  alias AlexClaw.LLM.Window
  alias AlexClaw.Workflows.LLMTransform

  describe "a step with no prompt template" do
    test "is an error, not its input handed back" do
      assert LLMTransform.run(%{input: "the diff"}) == {:error, :no_prompt_template}

      assert LLMTransform.run(%{prompt_template: "", input: "the diff"}) ==
               {:error, :no_prompt_template}
    end
  end

  describe "the prompt for a provider's budget" do
    @template "Review this diff:\n{input}\n\nAnswer in one line."

    test "with room for everything, the input is whole" do
      args = %{input: String.duplicate("a", 300)}

      assert {:ok, prompt} = LLMTransform.fitted_prompt(@template, args, 10_000)
      assert prompt =~ String.duplicate("a", 300)
      refute prompt =~ "trimmed"
    end

    test "an input larger than the budget is trimmed, and says so" do
      args = %{input: String.duplicate("a", 30_000)}
      budget = 1_000

      assert {:ok, prompt} = LLMTransform.fitted_prompt(@template, args, budget)
      assert prompt =~ "Review this diff:"
      assert prompt =~ "Answer in one line."
      assert prompt =~ "trimmed to fit"
      assert Window.estimate(prompt) <= budget
    end

    test "a template larger than the budget is refused" do
      args = %{input: "x"}
      mandatory = Window.estimate(String.replace(@template, "{input}", ""))

      assert {:error, {:does_not_fit, ^mandatory}} =
               LLMTransform.fitted_prompt(@template, args, mandatory - 1)
    end

    test "an unknown window gets the whole input" do
      args = %{input: String.duplicate("b", 20_000)}

      assert {:ok, prompt} = LLMTransform.fitted_prompt(@template, args, :unlimited)
      assert prompt =~ String.duplicate("b", 20_000)
    end

    test "no input at all is just the template" do
      assert {:ok, prompt} = LLMTransform.fitted_prompt(@template, %{}, 1_000)
      assert prompt =~ "Review this diff:"
    end
  end
end
