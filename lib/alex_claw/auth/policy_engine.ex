defmodule AlexClaw.Auth.PolicyEngine do
  @moduledoc """
  Evaluates authorization decisions based on context.

  Phase 1: Replicates existing flat permission checks + adds
  chain-depth enforcement and structured audit logging.

  Phase 3 will add configurable policy rules from DB.
  """

  alias AlexClaw.Auth.{AuthContext, AuditLog}

  @max_chain_depth 3

  @doc """
  Evaluate an authorization context.

  Returns `:allow` or `{:deny, reason}`.
  """
  @spec evaluate(AuthContext.t(), :all | [atom()]) :: :allow | {:deny, String.t()}
  def evaluate(%AuthContext{caller_type: :core} = ctx, :all) do
    AuditLog.log_allow(ctx)
    :allow
  end

  def evaluate(%AuthContext{} = ctx, permissions) when is_list(permissions) do
    with :ok <- check_chain_depth(ctx),
         :ok <- check_permission_list(ctx, permissions) do
      AuditLog.log_allow(ctx)
      :allow
    else
      {:deny, reason} = denial ->
        AuditLog.log_deny(ctx, reason)
        denial
    end
  end

  def evaluate(%AuthContext{} = ctx, _) do
    reason = "unknown permission state"
    AuditLog.log_deny(ctx, reason)
    {:deny, reason}
  end

  # --- Policy checks ---

  defp check_chain_depth(%AuthContext{chain_depth: depth}) when depth > @max_chain_depth do
    {:deny, "chain depth #{depth} exceeds maximum #{@max_chain_depth}"}
  end

  defp check_chain_depth(_ctx), do: :ok

  defp check_permission_list(%AuthContext{permission: permission}, permissions) do
    if permission in permissions do
      :ok
    else
      {:deny, "permission :#{permission} not declared"}
    end
  end
end
