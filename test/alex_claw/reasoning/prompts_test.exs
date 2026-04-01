defmodule AlexClaw.Reasoning.PromptsTest do
  use AlexClaw.DataCase, async: false
  @moduletag :unit

  alias AlexClaw.Reasoning.Prompts

  describe "planning/1" do
    test "builds prompt with all placeholders replaced" do
      prompt =
        Prompts.planning(%{
          goal: "Find recent Elixir news",
          skill_list: "- web_search: Search the web\n- rss_fetch: Fetch RSS feeds",
          working_memory: "User wants Elixir news",
          prior_knowledge: "From memory:\n- Elixir is a functional language",
          max_steps: 5
        })

      assert prompt =~ "Find recent Elixir news"
      assert prompt =~ "web_search: Search the web"
      assert prompt =~ "User wants Elixir news"
      assert prompt =~ "Elixir is a functional language"
      assert prompt =~ "5"
      refute prompt =~ "{goal}"
      refute prompt =~ "{skill_list}"
    end

    test "uses defaults for nil working_memory and prior_knowledge" do
      prompt =
        Prompts.planning(%{
          goal: "test",
          skill_list: "- skill: desc",
          working_memory: nil,
          prior_knowledge: nil,
          max_steps: 8
        })

      assert prompt =~ "No prior context yet."
      assert prompt =~ "None available."
    end

    test "uses custom template from config when set" do
      AlexClaw.Config.set("prompts.reasoning.planning", "CUSTOM: {goal} with {skill_list}",
        type: "string",
        category: "prompts"
      )

      prompt =
        Prompts.planning(%{
          goal: "test goal",
          skill_list: "skills here",
          working_memory: nil,
          prior_knowledge: nil,
          max_steps: 5
        })

      assert prompt == "CUSTOM: test goal with skills here"

      # Clean up
      AlexClaw.Config.set("prompts.reasoning.planning", "", type: "string", category: "prompts")
    end
  end

  describe "execution/1" do
    test "builds prompt with skill details" do
      prompt =
        Prompts.execution(%{
          skill_name: "web_search",
          skill_description: "Search the web using DuckDuckGo",
          step_description: "search for Elixir GenServer patterns",
          previous_results: "None yet.",
          working_memory: "Planning phase complete",
          user_guidance: nil
        })

      assert prompt =~ "web_search"
      assert prompt =~ "DuckDuckGo"
      assert prompt =~ "Elixir GenServer"
      assert prompt =~ "Planning phase complete"
      refute prompt =~ "User guidance"
    end

    test "includes user guidance when provided" do
      prompt =
        Prompts.execution(%{
          skill_name: "web_search",
          skill_description: "Search",
          step_description: "search",
          previous_results: "None.",
          working_memory: "wm",
          user_guidance: "Focus on official docs only"
        })

      assert prompt =~ "Focus on official docs only"
      assert prompt =~ "User guidance"
    end
  end

  describe "evaluation/1" do
    test "builds prompt with skill output" do
      prompt =
        Prompts.evaluation(%{
          goal: "Find news",
          step_description: "search web",
          skill_name: "web_search",
          skill_output: "Found 5 articles about Elixir",
          working_memory: "wm"
        })

      assert prompt =~ "Find news"
      assert prompt =~ "web_search"
      assert prompt =~ "Found 5 articles"
      assert prompt =~ "relevance"
      assert prompt =~ "completeness"
    end

    test "truncates long skill output" do
      long_output = String.duplicate("x", 5000)

      prompt =
        Prompts.evaluation(%{
          goal: "test",
          step_description: "step",
          skill_name: "skill",
          skill_output: long_output,
          working_memory: "wm"
        })

      assert prompt =~ "truncated"
      refute byte_size(prompt) > 10_000
    end

    test "handles nil skill output" do
      prompt =
        Prompts.evaluation(%{
          goal: "test",
          step_description: "step",
          skill_name: "skill",
          skill_output: nil,
          working_memory: "wm"
        })

      assert prompt =~ "(no output)"
    end
  end

  describe "decision/1" do
    test "builds prompt with iteration context" do
      prompt =
        Prompts.decision(%{
          goal: "Research topic",
          plan_summary: "1. search\n2. summarize",
          completed_steps: "Iteration 1: execute web_search [OK]",
          iteration: 3,
          max_iterations: 15,
          consecutive_failures: 0,
          working_memory: "Found some data",
          user_guidance: nil
        })

      assert prompt =~ "Research topic"
      assert prompt =~ "3"
      assert prompt =~ "15"
      assert prompt =~ "Found some data"
      assert prompt =~ "continue"
      assert prompt =~ "done"
      assert prompt =~ "stuck"
    end

    test "includes user guidance in decision prompt" do
      prompt =
        Prompts.decision(%{
          goal: "test",
          plan_summary: "plan",
          completed_steps: "none",
          iteration: 1,
          max_iterations: 15,
          consecutive_failures: 0,
          working_memory: "wm",
          user_guidance: "Skip step 2, go directly to summary"
        })

      assert prompt =~ "Skip step 2"
      assert prompt =~ "User guidance"
    end

    test "handles empty working memory" do
      prompt =
        Prompts.decision(%{
          goal: "test",
          plan_summary: "plan",
          completed_steps: "none",
          iteration: 1,
          max_iterations: 15,
          consecutive_failures: 2,
          working_memory: "",
          user_guidance: nil
        })

      # Should not crash, empty string is valid
      assert is_binary(prompt)
      assert prompt =~ "2"
    end
  end
end
