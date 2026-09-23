defmodule AlexClaw.Workflows.ExecutorEntryPointsTest do
  @moduledoc """
  Two ways into a run, and which one a caller gets is not a coin toss.

  `run_with_initial_input/2` hands the input to step 1. The other entry point
  feeds only a `receive_from_workflow` step: it exists for a run started by
  another node's `send_to_workflow`, and nothing else. Until 0.3.41 it was
  called `run_with_input/3`, one word away from the first, and two callers
  picked it expecting the first: the GitHub webhook (F7) and the MCP workflow
  tool (F8). Each dropped its input silently.

  So it is named for what it is — `run_remote_trigger/3` — and this reads
  `lib/` and fails when anything outside the cluster path calls it.
  """
  use ExUnit.Case, async: true
  @moduletag :docs

  alias AlexClaw.Workflows.Executor

  # The definition, and the one legitimate caller: the node that receives
  # another node's send_to_workflow.
  @allowed [
    "lib/alex_claw/workflows/executor.ex",
    "lib/alex_claw/cluster/manager.ex"
  ]

  # Callers that start a run with input meant for step 1. Each must go through
  # run_with_initial_input/2.
  @initial_input_callers [
    "lib/alex_claw_web/controllers/github_webhook_controller.ex",
    "lib/alex_claw/mcp/server.ex"
  ]

  defp sources, do: Path.wildcard("lib/**/*.ex")

  # A reference is code. A mention in a comment is prose, and prose may explain.
  defp code_lines(body) do
    body
    |> String.split("\n")
    |> Enum.reject(&(String.trim_leading(&1) |> String.starts_with?("#")))
  end

  defp references?(body, name) do
    Enum.any?(code_lines(body), &Regex.match?(~r/\b#{name}\b/, &1))
  end

  test "the remote-trigger entry point exists and the old name is gone" do
    Code.ensure_loaded!(Executor)

    assert function_exported?(Executor, :run_remote_trigger, 3)
    assert function_exported?(Executor, :run_with_initial_input, 2)

    for arity <- 1..3 do
      refute function_exported?(Executor, :run_with_input, arity),
             "Executor.run_with_input/#{arity} still exists — the name is the trap"
    end
  end

  test "nothing outside the cluster path calls run_remote_trigger" do
    offenders =
      for path <- sources(),
          path not in @allowed,
          references?(File.read!(path), "run_remote_trigger"),
          do: path

    assert offenders == [],
           """
           These modules start a run through the cluster entry point:

             #{Enum.join(offenders, "\n  ")}

           run_remote_trigger/3 delivers its input only to a receive_from_workflow
           step. To hand input to step 1, call Executor.run_with_initial_input/2.
           If this really is a run started by another node, add the file to
           @allowed here with the reason.
           """
  end

  test "no module still names run_with_input" do
    offenders =
      for path <- sources(), references?(File.read!(path), "run_with_input"), do: path

    assert offenders == [], "still named: #{Enum.join(offenders, ", ")}"
  end

  test "the webhook and the MCP workflow tool start runs with step-1 input" do
    for path <- @initial_input_callers do
      assert File.exists?(path), "#{path} does not exist — update this list"

      assert references?(File.read!(path), "run_with_initial_input"),
             "#{path} does not call Executor.run_with_initial_input/2"
    end
  end

  test "the allow-list has not gone stale" do
    for path <- @allowed do
      assert File.exists?(path), "#{path} is allow-listed and does not exist"

      assert references?(File.read!(path), "run_remote_trigger"),
             "#{path} no longer names run_remote_trigger — drop it from @allowed"
    end
  end
end
