defmodule AlexClaw.Skills.SkillInvocationBoundaryTest do
  @moduledoc """
  Every skill runs through one function, which checks that it is available
  (0.4.0 S5b, the last item; reports of 2026-09-25 on the call sites).

  S5b made the executor check a step's availability, and found that skill code
  was reached in other ways too: the circuit-breaker fallback called
  `mod.run(args)` directly, and chat commands reached skills through their own
  `handle/2` functions — bypassing both the availability check and the door.

  The rule, in two parts:
  1. `SafeExecutor.run/5` is the one place skill code executes, and it checks
     availability itself — so every path through it has the check without
     having to remember it (the step, the reasoning loop, run_skill, the
     generator's trial run, the fallback).
  2. Nothing else calls a skill's code: no `module.run(...)` outside
     SafeExecutor, and no entry point (chat, gateways, MCP, admin pages,
     controllers) calls a skill module at all — chat commands run skills
     through the door (`ControlPlane.perform(:run_skill, …)`).
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.SafeExecutor

  @sink "lib/alex_claw/auth/safe_executor.ex"

  @entry_points [
    "lib/alex_claw/dispatcher.ex",
    "lib/alex_claw/dispatcher/**/*.ex",
    "lib/alex_claw/gateway/**/*.ex",
    "lib/alex_claw/mcp/**/*.ex",
    "lib/alex_claw_web/live/**/*.ex",
    "lib/alex_claw_web/controllers/**/*.ex"
  ]

  defp code_lines(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reject(fn {line, _} -> String.trim_leading(line) |> String.starts_with?("#") end)
  end

  describe "the sink checks availability" do
    test "SafeExecutor refuses an unavailable skill before running it" do
      # Coder is not available as a step since S5b; the refusal must come from
      # the sink itself, not from any caller.
      assert {:error, {:unavailable, reason}} =
               SafeExecutor.run(AlexClaw.Skills.Coder, %{}, :core, nil, [])

      assert reason =~ ~r/Forge|not a workflow step/i
    end
  end

  describe "nothing but the sink calls a skill's run/1" do
    # A variable holding a skill module, then .run( — how the fallback did it.
    @direct ~r/\b(mod|module|skill_module|skill_mod|skill)\.run\(/

    test "the pattern recognises what it is for (no vacuous pass)" do
      assert Regex.match?(@direct, "mod.run(args)")
      assert Regex.match?(@direct, "module.run(args)")
      refute Regex.match?(@direct, "SafeExecutor.run(module, args, :core, nil, [])")

      assert Enum.any?(code_lines(@sink), fn {line, _} -> Regex.match?(@direct, line) end),
             "the sink itself does not match — the scan would prove nothing"
    end

    test "only SafeExecutor calls module.run(...)" do
      offenders =
        for path <- Path.wildcard("lib/**/*.ex"),
            path != @sink,
            {line, n} <- code_lines(path),
            Regex.match?(@direct, line),
            do: "#{path}:#{n}: #{String.trim(line)}"

      assert offenders == [],
             "skill code run outside SafeExecutor:\n" <> Enum.join(offenders, "\n")
    end
  end

  describe "no entry point calls a skill module" do
    # Every module under lib/alex_claw/skills/, by its short name
    # (research.ex -> Research, web_search.ex -> WebSearch).
    defp skill_names do
      "lib/alex_claw/skills/*.ex"
      |> Path.wildcard()
      |> Enum.map(&(&1 |> Path.basename(".ex") |> Macro.camelize()))
      |> Enum.reject(&(&1 in ~w(SkillApi SkillAPI Invoke SkillSupervisor)))
    end

    test "the list of skill modules is real (no vacuous pass)" do
      names = skill_names()
      assert "Research" in names
      assert "WebSearch" in names
      assert "GoogleTasks" in names
    end

    test "chat, gateways, MCP, admin pages and controllers never call one" do
      pattern =
        Regex.compile!("\\b(" <> Enum.join(skill_names(), "|") <> ")\\.(run|handle)\\(")

      offenders =
        for path <- Enum.flat_map(@entry_points, &Path.wildcard/1),
            {line, n} <- code_lines(path),
            Regex.match?(pattern, line),
            do: "#{path}:#{n}: #{String.trim(line)}"

      assert offenders == [],
             "entry points calling skill code directly (use ControlPlane.perform(:run_skill, …)):\n" <>
               Enum.join(offenders, "\n")
    end
  end

  test "the dead SkillSupervisor.run_skill/2 path is gone" do
    Code.ensure_loaded(AlexClaw.Workflows.SkillSupervisor)
    refute function_exported?(AlexClaw.Workflows.SkillSupervisor, :run_skill, 2)
  end
end
