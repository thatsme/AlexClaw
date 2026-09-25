defmodule AlexClaw.Auth.SafeExecutor do
  @moduledoc """
  Runs dynamic skills in a separate process with an attenuated
  capability token. The child process gets its own process dictionary,
  isolating it from the caller's auth state.

  Core skills run in-process (no overhead, trusted code).

  It is the one place skill code runs — a workflow step, the circuit-breaker
  fallback, a skill running another, the reasoning loop, the generator's
  trial run, a chat command — and it checks first that the skill is
  available (`AlexClaw.Workflows.StepConfig.available?/2`): an unavailable
  skill is refused with its reason, and none of its code runs.
  """
  require Logger

  alias AlexClaw.Auth.CapabilityToken
  alias AlexClaw.Skill
  alias AlexClaw.Workflows.StepConfig

  @default_timeout 30_000

  @doc """
  Execute a skill module with the given args and capability token.

  For dynamic skills: spawns a monitored task, sets the token
  in the child's process dictionary, collects the result.

  For core skills: runs in-process directly (no token needed).
  """
  @spec run(module(), map(), :core | :dynamic, CapabilityToken.t() | nil, keyword()) ::
          {:ok, any(), atom()} | {:ok, any()} | {:error, any()}
  def run(module, args, type, token, opts) do
    module
    |> StepConfig.available?(Map.get(args, :config))
    |> execute(module, args, type, token, opts)
  end

  defp execute(false, module, _args, _type, _token, _opts),
    do: {:error, {:unavailable, Skill.unavailable_reason(module, skill_name(module))}}

  defp execute(true, module, args, :core, _token, _opts), do: module.run(args)

  defp execute(true, module, args, :dynamic, token, opts) do
    timeout = opts[:timeout] || @default_timeout
    workflow_run_id = Process.get(:auth_workflow_run_id)
    chain_depth = Process.get(:auth_chain_depth, 0)

    task =
      Task.async(fn ->
        # Set auth context in child process
        if token, do: Process.put(:auth_token, token)
        Process.put(:auth_workflow_run_id, workflow_run_id)
        Process.put(:auth_chain_depth, chain_depth)

        module.run(args)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      nil ->
        Logger.warning("SafeExecutor: #{inspect(module)} timed out after #{timeout}ms")
        {:error, :skill_timeout}
    end
  end

  defp skill_name(module), do: module |> Module.split() |> List.last() |> Macro.underscore()
end
