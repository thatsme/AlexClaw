defmodule AlexClaw.Auth.SafeExecutor do
  @moduledoc """
  Runs dynamic skills in a separate process with an attenuated
  capability token. The child process gets its own process dictionary,
  isolating it from the caller's auth state.

  Core skills run in-process (no overhead, trusted code).
  """
  require Logger

  alias AlexClaw.Auth.CapabilityToken

  @default_timeout 30_000

  @doc """
  Execute a skill module with the given args and capability token.

  For dynamic skills: spawns a monitored task, sets the token
  in the child's process dictionary, collects the result.

  For core skills: runs in-process directly (no token needed).
  """
  @spec run(module(), map(), :core | :dynamic, CapabilityToken.t() | nil, keyword()) ::
          {:ok, any(), atom()} | {:ok, any()} | {:error, any()}
  def run(module, args, :core, _token, _opts) do
    module.run(args)
  end

  def run(module, args, :dynamic, token, opts) do
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
end
