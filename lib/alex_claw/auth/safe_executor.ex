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

  # The running skill's identity, in the process running it (S9, S8 C1).
  @identity :auth_skill
  # The secrets the running step was given placeholders for (S9, S8 H2/H3).
  @secrets :auth_secrets

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

  defp execute(true, module, args, :core, _token, opts),
    do: as_skill(module, fn -> with_secrets(opts[:secrets] || [], fn -> module.run(args) end) end)

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
        Process.put(@identity, module)
        Process.put(@secrets, MapSet.new(opts[:secrets] || []))

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

  @doc """
  The skill running in this process, as recorded when it was started here —
  what `AlexClaw.Skills.SkillAPI` checks a call against — or nil when no skill
  is running. A skill cannot set it: nothing that passes containment writes
  the process dictionary.
  """
  @spec running_skill() :: module() | nil
  def running_skill, do: Process.get(@identity)

  @doc """
  Run `fun` as the skill `module`: for core code that calls SkillAPI on a
  skill's behalf outside a run (the code generator, as the Coder skill). Not
  reachable from a skill: this module is outside the contained set. The
  previous identity is put back afterwards.
  """
  @spec as_skill(module(), (-> result)) :: result when result: term()
  def as_skill(module, fun) when is_atom(module) and is_function(fun, 0) do
    previous = Process.put(@identity, module)

    try do
      fun.()
    after
      restore_identity(previous)
    end
  end

  defp restore_identity(nil), do: Process.delete(@identity)
  defp restore_identity(previous), do: Process.put(@identity, previous)

  @doc """
  Whether the running step was given the secret `name`
  (`AlexClaw.Net.Credentials` and `AlexClaw.WebAutomation.Recording` attach
  only those). A process with no allow-list gets none (S9 fix review N1): code
  of AlexClaw's own that needs a secret by name states which, with
  `with_secrets/2`.
  """
  @spec secret_allowed?(String.t()) :: boolean()
  def secret_allowed?(name), do: allowed?(Process.get(@secrets), name)

  defp allowed?(nil, _name), do: false
  defp allowed?(given, name), do: MapSet.member?(given, name)

  @doc """
  Run `fun` with `names` as this process's allow-list, and put the previous
  one back afterwards: for a core skill's run, and for AlexClaw's own code that
  attaches secrets it names (the admin UI replaying a recording). Not
  reachable from a skill: this module is outside the contained set.
  """
  @spec with_secrets([String.t()], (-> result)) :: result when result: term()
  def with_secrets(names, fun) when is_list(names) and is_function(fun, 0) do
    previous = Process.put(@secrets, MapSet.new(names))

    try do
      fun.()
    after
      restore_secrets(previous)
    end
  end

  defp restore_secrets(nil), do: Process.delete(@secrets)
  defp restore_secrets(previous), do: Process.put(@secrets, previous)

  defp skill_name(module), do: module |> Module.split() |> List.last() |> Macro.underscore()
end
