defmodule AlexClaw.Auth.AuditLog do
  @moduledoc """
  Authorization audit logging — both Logger and DB persistence.

  Denials are always persisted (important for security review).
  Allows are logged at debug level only (too noisy for DB).
  Old entries are pruned periodically.
  """
  require Logger

  import Ecto.Query

  alias AlexClaw.Auth.{AuthContext, AuditEntry}
  alias AlexClaw.Repo

  @retention_days 30

  @doc "Log and persist an authorization denial."
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

    persist(ctx, "deny", reason)
  end

  @doc "Log an authorization allow (debug level, not persisted)."
  @spec log_allow(AuthContext.t()) :: :ok
  def log_allow(%AuthContext{} = ctx) do
    Logger.debug(
      "Auth allowed: #{inspect(ctx.caller)} :#{ctx.permission}",
      auth: :allowed,
      caller: inspect(ctx.caller),
      permission: ctx.permission
    )
  end

  @doc "Prune audit entries older than retention period."
  @spec prune() :: {non_neg_integer(), nil}
  def prune do
    cutoff = DateTime.add(DateTime.utc_now(), -@retention_days, :day)

    Repo.delete_all(
      from(e in AuditEntry, where: e.inserted_at < ^cutoff)
    )
  rescue
    _ -> {0, nil}
  end

  @doc "List recent audit entries."
  @spec recent(keyword()) :: [AuditEntry.t()]
  def recent(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    decision = Keyword.get(opts, :decision)

    AuditEntry
    |> maybe_filter_decision(decision)
    |> order_by([e], desc: e.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  rescue
    _ -> []
  end

  # --- Internals ---

  defp persist(%AuthContext{} = ctx, decision, reason) do
    %AuditEntry{
      caller: inspect(ctx.caller),
      caller_type: to_string(ctx.caller_type),
      permission: to_string(ctx.permission),
      decision: decision,
      reason: reason,
      workflow_run_id: ctx.workflow_run_id,
      chain_depth: ctx.chain_depth,
      inserted_at: DateTime.utc_now()
    }
    |> Repo.insert()
    |> case do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  rescue
    _ -> :ok
  end

  defp maybe_filter_decision(query, nil), do: query

  defp maybe_filter_decision(query, decision) do
    import Ecto.Query
    where(query, [e], e.decision == ^decision)
  end
end
