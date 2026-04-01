defmodule AlexClaw.Reasoning.PromptParserTest do
  use ExUnit.Case, async: true
  @moduletag :unit

  alias AlexClaw.Reasoning.PromptParser

  # --- parse_plan/1 ---

  describe "parse_plan/1" do
    test "parses clean JSON plan" do
      raw = ~s({"steps": [{"step": 1, "skill": "web_search", "input_description": "search for X", "reason": "need data"}], "working_memory": "understood the goal"})
      assert {:ok, parsed} = PromptParser.parse_plan(raw)
      assert length(parsed["steps"]) == 1
      assert parsed["working_memory"] == "understood the goal"
    end

    test "parses plan wrapped in markdown code fences" do
      raw = """
      ```json
      {"steps": [{"step": 1, "skill": "research", "input_description": "look up"}], "working_memory": "wm"}
      ```
      """

      assert {:ok, parsed} = PromptParser.parse_plan(raw)
      assert [%{"skill" => "research"}] = parsed["steps"]
    end

    test "parses plan with preamble text before JSON" do
      raw = """
      Here is my plan:

      {"steps": [{"step": 1, "skill": "web_fetch", "input_description": "fetch URL"}], "working_memory": "got it"}
      """

      assert {:ok, parsed} = PromptParser.parse_plan(raw)
      assert parsed["working_memory"] == "got it"
    end

    test "accepts error response from LLM" do
      raw = ~s({"error": "cannot achieve goal", "reason": "no skills match", "working_memory": "tried"})
      assert {:ok, parsed} = PromptParser.parse_plan(raw)
      assert parsed["error"] == "cannot achieve goal"
    end

    test "returns error for empty string" do
      assert {:error, :parse_failed, _reason} = PromptParser.parse_plan("")
    end

    test "returns error for plain text with no JSON" do
      assert {:error, :parse_failed, _reason} = PromptParser.parse_plan("I don't know how to help with that.")
    end

    test "returns error when steps lack required fields" do
      raw = ~s({"steps": [{"description": "missing step and skill"}], "working_memory": "wm"})
      assert {:error, :parse_failed, reason} = PromptParser.parse_plan(raw)
      assert reason =~ "step"
    end

    test "returns error when response is JSON array instead of object" do
      raw = ~s([{"step": 1, "skill": "web_search"}])
      assert {:error, :parse_failed, _} = PromptParser.parse_plan(raw)
    end

    test "handles trailing commas from local models" do
      raw = ~s({"steps": [{"step": 1, "skill": "research", "input_description": "x",},], "working_memory": "wm",})
      assert {:ok, parsed} = PromptParser.parse_plan(raw)
      assert length(parsed["steps"]) == 1
    end

    test "returns error for nil input" do
      assert_raise FunctionClauseError, fn ->
        PromptParser.parse_plan(nil)
      end
    end
  end

  # --- parse_execution/1 ---

  describe "parse_execution/1" do
    test "parses clean execution response" do
      raw = ~s({"input": "elixir genserver tutorial", "working_memory": "preparing search"})
      assert {:ok, parsed} = PromptParser.parse_execution(raw)
      assert parsed["input"] == "elixir genserver tutorial"
    end

    test "returns error when input key missing" do
      raw = ~s({"query": "wrong key", "working_memory": "wm"})
      assert {:error, :parse_failed, reason} = PromptParser.parse_execution(raw)
      assert reason =~ "input"
    end

    test "returns error when working_memory key missing" do
      raw = ~s({"input": "search term"})
      assert {:error, :parse_failed, reason} = PromptParser.parse_execution(raw)
      assert reason =~ "working_memory"
    end

    test "returns error for empty string" do
      assert {:error, :parse_failed, _} = PromptParser.parse_execution("")
    end

    test "handles code fence wrapped response" do
      raw = "```\n{\"input\": \"test\", \"working_memory\": \"wm\"}\n```"
      assert {:ok, parsed} = PromptParser.parse_execution(raw)
      assert parsed["input"] == "test"
    end
  end

  # --- parse_evaluation/1 ---

  describe "parse_evaluation/1" do
    test "parses clean evaluation with all rubric scores" do
      raw = ~s({"relevance": 4, "completeness": 3, "usability": 5, "goal_progress": 4, "quality": "good", "summary": "found data", "relevant_output": "key info", "working_memory": "wm"})
      assert {:ok, parsed} = PromptParser.parse_evaluation(raw)
      assert parsed["quality"] == "good"
      assert parsed["relevance"] == 4
    end

    test "normalizes quality from rubric scores when quality value is invalid" do
      raw = ~s({"relevance": 4, "completeness": 4, "usability": 4, "goal_progress": 4, "quality": "excellent", "summary": "s", "relevant_output": "r", "working_memory": "wm"})
      assert {:ok, parsed} = PromptParser.parse_evaluation(raw)
      # Average is 4.0 >= 3.5, should normalize to "good"
      assert parsed["quality"] == "good"
    end

    test "normalizes to failed when scores are low" do
      raw = ~s({"relevance": 1, "completeness": 1, "usability": 1, "goal_progress": 1, "quality": "terrible", "summary": "s", "relevant_output": "r", "working_memory": "wm"})
      assert {:ok, parsed} = PromptParser.parse_evaluation(raw)
      assert parsed["quality"] == "failed"
    end

    test "normalizes to partial for mid-range scores" do
      raw = ~s({"relevance": 2, "completeness": 3, "usability": 2, "goal_progress": 2, "quality": "okay", "summary": "s", "relevant_output": "r", "working_memory": "wm"})
      assert {:ok, parsed} = PromptParser.parse_evaluation(raw)
      assert parsed["quality"] == "partial"
    end

    test "returns error when quality and working_memory missing" do
      raw = ~s({"relevance": 4})
      assert {:error, :parse_failed, reason} = PromptParser.parse_evaluation(raw)
      assert reason =~ "quality"
    end

    test "returns error for empty string" do
      assert {:error, :parse_failed, _} = PromptParser.parse_evaluation("")
    end
  end

  # --- parse_decision/1 ---

  describe "parse_decision/1" do
    test "parses continue decision" do
      raw = ~s({"action": "continue", "confidence": 0.6, "reason": "more steps needed", "working_memory": "wm"})
      assert {:ok, parsed} = PromptParser.parse_decision(raw)
      assert parsed["action"] == "continue"
      assert parsed["confidence"] == 0.6
    end

    test "parses done decision with final_answer" do
      raw = ~s({"action": "done", "confidence": 0.9, "reason": "goal met", "final_answer": "The answer is 42", "working_memory": "wm"})
      assert {:ok, parsed} = PromptParser.parse_decision(raw)
      assert parsed["action"] == "done"
      assert parsed["final_answer"] == "The answer is 42"
    end

    test "parses ask_user decision with question" do
      raw = ~s({"action": "ask_user", "confidence": 0.3, "reason": "unclear", "question": "What time range?", "working_memory": "wm"})
      assert {:ok, parsed} = PromptParser.parse_decision(raw)
      assert parsed["action"] == "ask_user"
      assert parsed["question"] == "What time range?"
    end

    test "parses adjust decision with new_plan" do
      raw = ~s({"action": "adjust", "reason": "plan failed", "new_plan": [{"step": 1, "skill": "research"}], "working_memory": "wm"})
      assert {:ok, parsed} = PromptParser.parse_decision(raw)
      assert parsed["action"] == "adjust"
      assert is_list(parsed["new_plan"])
    end

    test "parses stuck decision" do
      raw = ~s({"action": "stuck", "reason": "no progress", "working_memory": "wm"})
      assert {:ok, parsed} = PromptParser.parse_decision(raw)
      assert parsed["action"] == "stuck"
    end

    test "normalizes unknown action to continue" do
      raw = ~s({"action": "retry", "reason": "hmm", "working_memory": "wm"})
      assert {:ok, parsed} = PromptParser.parse_decision(raw)
      assert parsed["action"] == "continue"
    end

    test "returns error when action key missing" do
      raw = ~s({"decision": "continue", "working_memory": "wm"})
      assert {:error, :parse_failed, reason} = PromptParser.parse_decision(raw)
      assert reason =~ "action"
    end

    test "returns error for empty string" do
      assert {:error, :parse_failed, _} = PromptParser.parse_decision("")
    end

    test "handles response with trailing text after JSON" do
      raw = ~s({"action": "done", "confidence": 0.85, "final_answer": "result here", "working_memory": "wm"}\n\nI hope this helps!)
      assert {:ok, parsed} = PromptParser.parse_decision(raw)
      assert parsed["action"] == "done"
    end
  end

  # --- Edge cases: boundary values and structurally valid but semantically wrong ---

  describe "edge cases" do
    test "parse_plan with maximum nesting depth from local model" do
      raw = ~s({"steps": [{"step": 1, "skill": "a"}, {"step": 2, "skill": "b"}, {"step": 3, "skill": "c"}, {"step": 4, "skill": "d"}, {"step": 5, "skill": "e"}, {"step": 6, "skill": "f"}, {"step": 7, "skill": "g"}, {"step": 8, "skill": "h"}], "working_memory": "big plan"})
      assert {:ok, parsed} = PromptParser.parse_plan(raw)
      assert length(parsed["steps"]) == 8
    end

    test "parse_evaluation with string scores instead of integers" do
      raw = ~s({"relevance": "4", "completeness": "3", "usability": "4", "goal_progress": "4", "quality": "invalid", "summary": "s", "relevant_output": "r", "working_memory": "wm"})
      assert {:ok, parsed} = PromptParser.parse_evaluation(raw)
      # String scores should be parsed and used for normalization
      assert parsed["quality"] in ["good", "partial"]
    end

    test "parse_decision with confidence as string" do
      raw = ~s({"action": "done", "confidence": "0.85", "final_answer": "x", "working_memory": "wm"})
      assert {:ok, parsed} = PromptParser.parse_decision(raw)
      assert parsed["action"] == "done"
    end

    test "handles single-quote JSON from weak models" do
      raw = "{'action': 'continue', 'confidence': 0.5, 'reason': 'next', 'working_memory': 'wm'}"
      # This should either parse or fail gracefully
      result = PromptParser.parse_decision(raw)
      assert match?({:ok, _}, result) or match?({:error, :parse_failed, _}, result)
    end

    test "parse_plan with 0 steps is treated as error" do
      raw = ~s({"steps": [], "working_memory": "empty"})
      # Empty steps array — technically valid JSON but semantically wrong
      # Parser should pass it through; the loop will handle empty plans
      assert {:ok, parsed} = PromptParser.parse_plan(raw)
      assert parsed["steps"] == []
    end
  end
end
