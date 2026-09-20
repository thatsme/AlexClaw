defmodule AlexClaw.Auth.AuditLog do
  @moduledoc """
  Authorization audit logging — both Logger and DB persistence.

  Denials are always persisted (important for security review).
  Allows are logged at debug level only (too noisy for DB).
  Old entries are pruned periodically.
  """
  require Logger

  import Ecto.Query

  alias AlexClaw.Auth.{AuditEntry, AuthContext}
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

  @doc """
  Record a change to one admin session's elevation.

  The session is named by fingerprint, never by its sid: this row is durable
  and the sid is a live session credential.
  """
  @spec log_elevation(:granted | :revoked | :expired, String.t(), String.t() | nil) :: :ok
  def log_elevation(event, session_fingerprint, detail \\ nil) do
    Logger.info("Admin elevation #{event} for session #{session_fingerprint}",
      auth: :elevation,
      elevation: event
    )

    insert_entry(%{
      caller: "admin:" <> session_fingerprint,
      caller_type: "admin",
      permission: "admin.elevation",
      decision: to_string(event),
      reason: detail
    })
  end

  @doc """
  Record a control-plane change made by an elevated admin session.

  `detail` says what changed, with secrets already masked by the caller — the
  row exists to answer "who changed this, and from what to what", which a
  masked value still answers.
  """
  @spec log_admin_write(String.t(), String.t()) :: :ok
  def log_admin_write(session_fingerprint, detail) do
    Logger.info("Admin write by #{session_fingerprint}: #{detail}", auth: :admin_write)

    insert_entry(%{
      caller: "admin:" <> session_fingerprint,
      caller_type: "admin",
      permission: "admin.control_plane",
      decision: "write",
      reason: detail
    })
  end

  @doc "Record a control-plane change refused for want of an elevation."
  @spec log_admin_refusal(String.t(), String.t()) :: :ok
  def log_admin_refusal(session_fingerprint, detail) do
    Logger.warning("Admin write refused for #{session_fingerprint}: #{detail}", auth: :denied)

    insert_entry(%{
      caller: "admin:" <> session_fingerprint,
      caller_type: "admin",
      permission: "admin.control_plane",
      decision: "deny",
      reason: "not elevated — " <> detail
    })
  end

  @doc "Prune audit entries older than retention period."
  @spec prune() :: {non_neg_integer(), nil}
  def prune do
    cutoff = DateTime.add(DateTime.utc_now(), -@retention_days, :day)

    Repo.delete_all(from(e in AuditEntry, where: e.inserted_at < ^cutoff))
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
    insert_entry(%{
      caller: inspect(ctx.caller),
      caller_type: to_string(ctx.caller_type),
      permission: to_string(ctx.permission),
      decision: decision,
      reason: reason,
      workflow_run_id: ctx.workflow_run_id,
      chain_depth: ctx.chain_depth
    })
  end

  # Best effort by design: the action being audited has already happened, and
  # failing it now because its record could not be written would trade a lost
  # row for a lost action.
  defp insert_entry(attrs) do
    %AuditEntry{}
    |> AuditEntry.changeset(Map.put(attrs, :inserted_at, DateTime.utc_now()))
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
