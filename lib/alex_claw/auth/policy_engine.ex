defmodule AlexClaw.Auth.PolicyEngine do
  @moduledoc """
  Evaluates authorization decisions based on context.

  Checks in order:
  1. Core skills → always allow (fast path)
  2. Chain depth → deny if too deep
  3. Capability token → deny if token present and lacks permission
  4. Flat permission list → deny if permission not declared

  Phase 3 will add configurable policy rules from DB.
  """

  alias AlexClaw.Auth.{AuthContext, AuditLog, CapabilityToken}

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
         :ok <- check_token(ctx),
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

  defp check_token(%AuthContext{token: nil}), do: :ok

  defp check_token(%AuthContext{token: %CapabilityToken{} = token, permission: permission}) do
    case CapabilityToken.verify(token) do
      {:ok, _perms} ->
        if CapabilityToken.has_permission?(token, permission) do
          :ok
        else
          {:deny, "token does not grant :#{permission}"}
        end

      {:error, :invalid_token} ->
        {:deny, "invalid capability token"}

      {:error, :token_expired} ->
        {:deny, "capability token expired"}

      {:error, :max_depth_exceeded} ->
        {:deny, "token max depth exceeded"}
    end
  end

  defp check_token(_ctx), do: :ok

  defp check_permission_list(%AuthContext{permission: permission}, permissions) do
    if permission in permissions do
      :ok
    else
      {:deny, "permission :#{permission} not declared"}
    end
  end
end
