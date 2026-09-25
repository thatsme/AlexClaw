defmodule AlexClaw.Skills.Invoke do
  @moduledoc """
  One skill running another: performed as `:run_skill` through
  `AlexClaw.ControlPlane.perform/3`, never called from an entry point.

  A privileged skill — one that reaches the host, the filesystem, the network
  or the skill loader, and does not check a second factor inside `run/1` — is
  refused here and audited; it runs only as `:run_privileged_skill`, from the
  admin UI. The target runs with the caller's capability token narrowed to
  the target's own permissions.
  """

  alias AlexClaw.Auth.{AuditLog, AuthContext, CapabilityToken}
  alias AlexClaw.Workflows.SkillRegistry

  @privileged_skills ~w(shell coder db_backup web_automation)

  @doc "The skills only the admin UI may run, with the elevation."
  @spec privileged_skills() :: [String.t()]
  def privileged_skills, do: @privileged_skills

  @doc "Run the skill `skill_name` with `args` for `caller`: its `run/1` result."
  @spec run(module(), String.t(), map()) ::
          {:ok, term()} | {:ok, term(), atom()} | {:error, term()}
  def run(caller, skill_name, _args) when skill_name in @privileged_skills do
    AuditLog.log_deny(
      AuthContext.build(caller, :skill_invoke, SkillRegistry.get_permissions(caller)),
      "cross-skill invocation of privileged skill '#{skill_name}'"
    )

    {:error, :privileged_skill}
  end

  def run(_caller, skill_name, args),
    do: skill_name |> SkillRegistry.resolve() |> invoke(skill_name, args)

  @doc "Run the privileged skill `skill_name` with `args` (`:run_privileged_skill`)."
  @spec run_privileged(String.t(), map()) ::
          {:ok, term()} | {:ok, term(), atom()} | {:error, term()}
  def run_privileged(skill_name, args) when skill_name in @privileged_skills,
    do: skill_name |> SkillRegistry.resolve() |> invoke(skill_name, args)

  def run_privileged(_skill_name, _args), do: {:error, :not_privileged}

  defp invoke({:error, :unknown_skill}, skill_name, _args),
    do: {:error, {:unknown_skill, skill_name}}

  defp invoke({:ok, target_module}, _skill_name, args) do
    depth = Process.get(:auth_chain_depth, 0)
    Process.put(:auth_chain_depth, depth + 1)

    current_token = Process.get(:auth_token)
    attenuated = attenuate_for(current_token, SkillRegistry.get_permissions(target_module))
    if attenuated, do: Process.put(:auth_token, attenuated)

    try do
      target_module.run(args)
    after
      Process.put(:auth_chain_depth, depth)
      if current_token, do: Process.put(:auth_token, current_token)
    end
  end

  # Narrow the caller's token to the target skill's permissions. Anything that
  # cannot be attenuated falls back to the caller's own token unchanged.
  defp attenuate_for(nil, _target_perms), do: nil

  defp attenuate_for(current_token, target_perms) when is_list(target_perms) do
    case CapabilityToken.attenuate(current_token, target_perms) do
      {:ok, token} -> token
      _ -> current_token
    end
  end

  defp attenuate_for(current_token, _target_perms), do: current_token
end
