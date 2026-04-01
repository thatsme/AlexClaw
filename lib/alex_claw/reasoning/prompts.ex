defmodule AlexClaw.Reasoning.Prompts do
  @moduledoc """
  Builds structured prompts for the four reasoning loop phases.
  All templates are read from Config and support runtime editing.
  Each prompt threads `working_memory` to prevent context fragmentation.
  """

  alias AlexClaw.Config

  @default_planning_prompt """
  You are a task planner. Given a goal, decompose it into a sequence of steps.

  Available skills (you may ONLY use these):
  {skill_list}

  Goal: {goal}

  Prior knowledge:
  {prior_knowledge}

  Current understanding:
  {working_memory}

  Respond with ONLY valid JSON. No explanation before or after.
  {
    "steps": [
      {"step": 1, "skill": "skill_name", "input_description": "what to pass", "reason": "why this step"}
    ],
    "working_memory": "summary of your understanding of the goal and plan"
  }

  Rules:
  - Maximum {max_steps} steps
  - Only use skills from the list above
  - If the goal cannot be achieved with available skills, return: {"error": "cannot achieve goal", "reason": "explanation", "working_memory": "what you understood"}
  """

  @default_execution_prompt """
  You are preparing input for a skill execution.

  Skill: {skill_name}
  Skill description: {skill_description}
  Step goal: {step_description}
  Previous results: {previous_results}

  Current understanding:
  {working_memory}

  {user_guidance_section}

  Respond with ONLY valid JSON. No explanation before or after.
  {
    "input": "the text or query to pass to the skill",
    "working_memory": "updated understanding after considering this step"
  }
  """

  @default_evaluation_prompt """
  You executed a skill and got a result. Evaluate it against the step goal and overall goal.

  Overall goal: {goal}
  Current step goal: {step_description}
  Skill: {skill_name}
  Result (may be truncated): {skill_output}

  Current understanding:
  {working_memory}

  Rate each criterion 1-5:
  - relevance: did the output address the step goal?
  - completeness: is the output sufficient or partial?
  - usability: can the next step use this output?
  - goal_progress: did this move closer to the overall goal?

  Respond with ONLY valid JSON. No explanation before or after.
  {
    "relevance": 4,
    "completeness": 3,
    "usability": 4,
    "goal_progress": 3,
    "quality": "good or partial or failed",
    "summary": "one sentence summary of what was achieved",
    "relevant_output": "key information to carry forward",
    "working_memory": "updated understanding incorporating the result"
  }

  Quality rules: "good" if average score >= 3.5, "partial" if >= 2.0, "failed" otherwise.
  """

  @default_decision_prompt """
  You are deciding the next action in a reasoning loop.

  Goal: {goal}
  Plan: {plan_summary}
  Completed steps so far: {completed_steps}
  Current iteration: {iteration} of {max_iterations}
  Consecutive failures: {consecutive_failures}

  Current understanding:
  {working_memory}

  {user_guidance_section}

  Respond with ONLY valid JSON. No explanation before or after.
  {
    "action": "continue or adjust or ask_user or done or stuck",
    "confidence": 0.8,
    "reason": "why this action",
    "question": "only if action is ask_user — what do you need from the user?",
    "new_plan": "only if action is adjust — array of new step objects",
    "final_answer": "only if action is done — the complete answer to the goal",
    "working_memory": "updated understanding"
  }

  Rules:
  - "done" if the goal has been achieved — include confidence (0.0-1.0) and final_answer
  - "stuck" if you cannot make progress
  - "ask_user" if you need clarification — include the question
  - "adjust" if the plan needs changing — include new_plan as JSON array
  - "continue" to proceed with the next planned step
  """

  @spec planning(map()) :: String.t()
  def planning(%{goal: goal, skill_list: skill_list, working_memory: wm, prior_knowledge: pk, max_steps: max_steps}) do
    template = config_or_default("prompts.reasoning.planning", @default_planning_prompt)

    template
    |> replace("{goal}", goal)
    |> replace("{skill_list}", skill_list)
    |> replace("{working_memory}", wm || "No prior context yet.")
    |> replace("{prior_knowledge}", pk || "None available.")
    |> replace("{max_steps}", to_string(max_steps))
  end

  @spec execution(map()) :: String.t()
  def execution(%{
        skill_name: skill_name,
        skill_description: skill_desc,
        step_description: step_desc,
        previous_results: prev,
        working_memory: wm,
        user_guidance: guidance
      }) do
    template = config_or_default("prompts.reasoning.execution", @default_execution_prompt)

    template
    |> replace("{skill_name}", skill_name)
    |> replace("{skill_description}", skill_desc || "No description available.")
    |> replace("{step_description}", step_desc)
    |> replace("{previous_results}", prev || "None yet.")
    |> replace("{working_memory}", wm || "")
    |> replace("{user_guidance_section}", guidance_section(guidance))
  end

  @spec evaluation(map()) :: String.t()
  def evaluation(%{
        goal: goal,
        step_description: step_desc,
        skill_name: skill_name,
        skill_output: output,
        working_memory: wm
      }) do
    template = config_or_default("prompts.reasoning.evaluation", @default_evaluation_prompt)

    truncated = truncate_output(output, 3000)

    template
    |> replace("{goal}", goal)
    |> replace("{step_description}", step_desc)
    |> replace("{skill_name}", skill_name)
    |> replace("{skill_output}", truncated)
    |> replace("{working_memory}", wm || "")
  end

  @spec decision(map()) :: String.t()
  def decision(%{
        goal: goal,
        plan_summary: plan,
        completed_steps: completed,
        iteration: iteration,
        max_iterations: max_iter,
        consecutive_failures: failures,
        working_memory: wm,
        user_guidance: guidance
      }) do
    template = config_or_default("prompts.reasoning.decision", @default_decision_prompt)

    template
    |> replace("{goal}", goal)
    |> replace("{plan_summary}", plan)
    |> replace("{completed_steps}", completed)
    |> replace("{iteration}", to_string(iteration))
    |> replace("{max_iterations}", to_string(max_iter))
    |> replace("{consecutive_failures}", to_string(failures))
    |> replace("{working_memory}", wm || "")
    |> replace("{user_guidance_section}", guidance_section(guidance))
  end

  defp guidance_section(nil), do: ""
  defp guidance_section(""), do: ""

  defp guidance_section(text) do
    "User guidance (incorporate this into your decision):\n#{text}"
  end

  defp replace(template, placeholder, value) do
    String.replace(template, placeholder, value)
  end

  defp truncate_output(nil, _max), do: "(no output)"
  defp truncate_output(output, max) when byte_size(output) <= max, do: output

  defp truncate_output(output, max) do
    String.slice(output, 0, max) <> "\n... (truncated, #{byte_size(output)} bytes total)"
  end

  defp config_or_default(key, default) do
    case Config.get(key) do
      nil -> default
      "" -> default
      value -> value
    end
  end
end
