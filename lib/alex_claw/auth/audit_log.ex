defmodule AlexClaw.Auth.AuditLog do
  @moduledoc """
  Structured logging for authorization decisions.

  Phase 1: Logger-based. Phase 3 will add DB persistence.
  """
  require Logger

  alias AlexClaw.Auth.AuthContext

  @doc "Log an authorization denial with full context."
  @spec log_deny(AuthContext.t(), String.t()) :: :ok
  def log_deny(%AuthContext{} = ctx, reason) do
    Logger.warning(
      "Auth denied: #{inspect(ctx.caller)} requires :#{ctx.permission} — #{reason}",
      auth: :denied,
      caller: inspect(ctx.caller),
      caller_type: ctx.caller_type,
      permission: ctx.permission,
      chain_depth: ctx.chain_depth,
      workflow_run_id: ctx.workflow_run_id
    )
  end

  @doc "Log an authorization allow (debug level, off by default)."
  @spec log_allow(AuthContext.t()) :: :ok
  def log_allow(%AuthContext{} = ctx) do
    Logger.debug(
      "Auth allowed: #{inspect(ctx.caller)} :#{ctx.permission}",
      auth: :allowed,
      caller: inspect(ctx.caller),
      permission: ctx.permission
    )
  end
end
