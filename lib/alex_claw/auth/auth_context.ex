defmodule AlexClaw.Auth.AuthContext do
  @moduledoc """
  Authorization context for a single permission check.

  Built internally by SkillAPI.check_permission/2 for skill-level checks,
  or by MCP.Server for external tool invocations. Carries the who/what/when/where
  needed for context-aware policy evaluation.

  Caller types:
  - `:core` — built-in skills, fast-path allowed
  - `:dynamic` — user-loaded skills, full policy evaluation
  - `:mcp` — external MCP client calls, full policy evaluation (no fast path)
  """

  @enforce_keys [:caller, :caller_type, :permission]
  defstruct [
    :caller,
    :caller_type,
    :permission,
    :workflow_run_id,
    :tool_name,
    chain_depth: 0,
    timestamp: nil,
    token: nil
  ]

  @type t :: %__MODULE__{
          caller: module() | String.t(),
          caller_type: :core | :dynamic | :mcp,
          permission: atom(),
          workflow_run_id: integer() | nil,
          tool_name: String.t() | nil,
          chain_depth: non_neg_integer(),
          timestamp: DateTime.t() | nil,
          token: any()
        }

  @doc "Build context from the current process state and skill module info."
  @spec build(module(), atom(), :all | [atom()]) :: t()
  def build(skill_module, permission, permissions) do
    %__MODULE__{
      caller: skill_module,
      caller_type: if(permissions == :all, do: :core, else: :dynamic),
      permission: permission,
      workflow_run_id: Process.get(:auth_workflow_run_id),
      chain_depth: Process.get(:auth_chain_depth, 0),
      timestamp: DateTime.utc_now(),
      token: Process.get(:auth_token)
    }
  end

  @doc "Build context for an MCP tool invocation (no process dictionary dependency)."
  @spec build_mcp(String.t(), atom()) :: t()
  def build_mcp(tool_name, permission) do
    %__MODULE__{
      caller: "mcp:#{tool_name}",
      caller_type: :mcp,
      permission: permission,
      tool_name: tool_name,
      chain_depth: 0,
      timestamp: DateTime.utc_now(),
      token: nil
    }
  end
end
