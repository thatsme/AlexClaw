defmodule AlexClaw.Auth.AuditLog do
  @moduledoc """
  Authorization audit logging — both Logger and DB persistence.

  Denials are always persisted (important for security review).
  Allows are logged at debug level only (too noisy for DB).
  Old entries are pruned periodically.
  """
  require Logger

  import Ecto.Query

  alias AlexClaw.Auth.{AuditEntry, AuditLoss, AuthContext, Principal}
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
  Record a control-plane change that was refused.

  `reason` separates the two refusals that look alike in a log and are not:
  `:not_elevated` is a session that can unlock and has not, `:no_second_factor`
  is an instance where nothing can unlock until 2FA is configured.
  """
  @spec log_admin_refusal(String.t(), :not_elevated | :no_second_factor, String.t()) :: :ok
  def log_admin_refusal(session_fingerprint, reason, detail) do
    Logger.warning("Admin write refused (#{reason}) for #{session_fingerprint}: #{detail}",
      auth: :denied
    )

    insert_entry(%{
      caller: "admin:" <> session_fingerprint,
      caller_type: "admin",
      permission: "admin.control_plane",
      decision: "deny",
      reason: "#{reason} — #{detail}"
    })
  end

  @doc """
  Write the row for a control-plane change, and say whether it was written.

  Unlike the `log_*` functions this is not best effort: it is called inside the
  change's own transaction by `AlexClaw.ControlPlane.gated/4`, and a row that
  could not be written refuses the change. The loss is still reported, like any
  other.
  """
  @spec record_admin_write(String.t(), String.t()) :: :ok | {:error, term()}
  def record_admin_write(session_fingerprint, detail) do
    Logger.info("Admin write by #{session_fingerprint}: #{detail}", auth: :admin_write)
    record(admin_entry(session_fingerprint, "write", detail))
  end

  @doc """
  Write the row for what a control-plane change actually did outside the
  database — a node answering a ping or not — after the change was committed.
  """
  @spec record_admin_outcome(String.t(), String.t()) :: :ok | {:error, term()}
  def record_admin_outcome(session_fingerprint, detail) do
    record(admin_entry(session_fingerprint, "outcome", detail))
  end

  defp admin_entry(session_fingerprint, decision, detail) do
    stamp(%{
      caller: "admin:" <> session_fingerprint,
      caller_type: "admin",
      permission: "admin.control_plane",
      decision: decision,
      reason: detail
    })
  end

  defp record(entry) do
    entry
    |> write()
    |> recorded(entry)
  end

  defp recorded({:ok, _row}, _entry), do: :ok

  defp recorded({:error, reason}, entry) do
    kept({:error, reason}, entry)
    {:error, reason}
  end

  @doc """
  Record one second-factor attempt.

  `method` says where the code came from — typed into the admin UI, or sent to
  a gateway. `factor` says what was presented: the authenticator, or one of the
  recovery codes. They answer different questions, and the second is the one
  that matters after the fact — a recovery code being spent means the
  authenticator is gone, which is either an operator having a bad day or
  someone else having a good one.

  A refused attempt carries `:unknown`, because a code that matched nothing is
  not evidence of which kind it was meant to be.
  """
  @spec log_code_attempt(
          :accepted | :refused,
          String.t(),
          :web | :gateway,
          :totp | :recovery_code | :unknown
        ) :: :ok
  def log_code_attempt(outcome, session_fingerprint, method, factor) do
    Logger.info("2FA #{factor} #{outcome} (#{method}) for #{session_fingerprint}",
      auth: :code_attempt
    )

    insert_entry(%{
      caller: "admin:" <> session_fingerprint,
      caller_type: "admin",
      permission: "admin.second_factor",
      decision: to_string(outcome),
      reason: "method: #{method}, factor: #{factor}"
    })
  end

  @doc "Record that wrong codes have locked web code entry for the whole instance."
  @spec log_code_lockout(pos_integer(), integer()) :: :ok
  def log_code_lockout(failures, until) do
    insert_entry(%{
      caller: "admin:instance",
      caller_type: "admin",
      permission: "admin.second_factor",
      decision: "deny",
      reason: "web code entry locked after #{failures} wrong codes, until #{until}"
    })
  end

  @doc "Record that a fresh set of recovery codes was generated."
  @spec log_recovery_codes(:generated, pos_integer()) :: :ok
  def log_recovery_codes(:generated, count) do
    Logger.info("#{count} recovery codes generated", auth: :recovery_codes)

    insert_entry(%{
      caller: "admin:recovery",
      caller_type: "admin",
      permission: "admin.recovery_codes",
      decision: "generated",
      reason: "#{count} codes, replacing any earlier set"
    })
  end

  @doc """
  Record that a recovery code was spent.

  Worth its own row rather than an ordinary code attempt: a recovery code being
  used means the authenticator is gone, which is either an operator having a
  bad day or someone else having a good one.
  """
  @spec log_recovery_code_used(non_neg_integer()) :: :ok
  def log_recovery_code_used(remaining) do
    Logger.warning("A recovery code was used — #{remaining} remaining", auth: :recovery_codes)

    insert_entry(%{
      caller: "admin:recovery",
      caller_type: "admin",
      permission: "admin.recovery_codes",
      decision: "accepted",
      reason: "recovery code used, #{remaining} remaining"
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

  # The caller is inspected without limits: inspect/1 cuts a string at 4096
  # characters, and an audit row must hold what happened, not most of it.
  defp persist(%AuthContext{} = ctx, decision, reason) do
    insert_entry(%{
      caller: inspect(ctx.caller, limit: :infinity, printable_limit: :infinity),
      caller_type: to_string(ctx.caller_type),
      permission: to_string(ctx.permission),
      decision: decision,
      reason: reason,
      workflow_run_id: ctx.workflow_run_id,
      chain_depth: ctx.chain_depth
    })
  end

  defp insert_entry(attrs) do
    entry = stamp(attrs)

    entry
    |> write()
    |> kept(entry)
  end

  # Whose authority, and when: added to every row, whichever path writes it.
  defp stamp(attrs) do
    attrs
    |> Map.merge(Principal.audit_fields())
    |> Map.put(:inserted_at, DateTime.utc_now())
  end

  # Best effort by design: the action being audited has already happened, and
  # failing it now because its record could not be written would trade a lost
  # row for a lost action. A lost row is loud instead — see AuditLoss.
  #
  # The catch matters as much as the rescue. A database that has gone away exits
  # rather than raising, and an unguarded exit propagates to whoever called.
  # The callers that own a :protected security table keep these writes off
  # their own process for that reason — Elevation and CodeAttempts each start a
  # supervised task rather than insert inline. This is the defence in depth
  # behind that, and the whole of it for every other caller.
  defp write(entry) do
    %AuditEntry{}
    |> AuditEntry.changeset(entry)
    |> Repo.insert()
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, reason -> {:error, reason}
  end

  # Every way of not writing the row ends here, including the changeset that
  # refused it — which used to be the one failure nobody heard about.
  defp kept({:ok, _row}, _entry), do: :ok
  defp kept({:error, %Ecto.Changeset{errors: errors}}, entry), do: AuditLoss.lost(entry, errors)
  defp kept({:error, reason}, entry), do: AuditLoss.lost(entry, reason)

  defp maybe_filter_decision(query, nil), do: query

  defp maybe_filter_decision(query, decision) do
    import Ecto.Query
    where(query, [e], e.decision == ^decision)
  end
end
