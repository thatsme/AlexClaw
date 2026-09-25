defmodule AlexClaw.ControlPlane do
  @moduledoc """
  The one path by which the control plane changes.

  Configuration, authorization policies, LLM providers, API resources, cluster
  membership and workflows decide what the agent does unattended. A change to
  any of them from the admin UI goes through `gated/4`, which holds three
  things together:

    * **Elevation.** The session must hold one. Without it nothing runs, and
      the refusal is audited.
    * **The audit row and the change are one transaction.** The row is written
      first; if it cannot be written, the change is not made. If the change
      fails, its row is rolled back with it. The log never records a change
      that did not happen, and no change happens that the log does not record.
    * **Effects outside the database run after commit.** A cache update, a
      broadcast, a message to another node cannot be rolled back, so they are
      not attempted until there is nothing left to roll back. Such an effect is
      written to be safe to repeat.

  An effect whose result matters — another node answering, or not — is
  recorded by `outcome/3` once it is known: the first row says what was
  intended, the second what happened.

  ## The one door

  Every privileged action is named in `catalogue/0`: for each entry point
  that may ask for it, the proof it needs — `:none`, `:elevation` (the
  session's 2FA window) or `:code` (a code for this action alone). An entry
  point not listed may not ask at all. `authorize/2` applies the catalogue;
  `perform/3` authorizes, runs the action (`AlexClaw.ControlPlane.Actions`)
  and audits every attempt, allowed or refused, naming the action and the
  entry point. A change runs with its audit row in one transaction, as in
  `gated/4`; an effect — a run, a download — starts once its row is written.
  """

  alias AlexClaw.Auth.{AuditLog, CodeEntry, Elevation, Principal}
  alias AlexClaw.ControlPlane.{Actions, Context}
  alias AlexClaw.Repo

  @authoring %{admin_ui: :elevation}

  @catalogue %{
    # control plane
    save_workflow: @authoring,
    delete_workflow: @authoring,
    duplicate_workflow: @authoring,
    import_workflow: @authoring,
    save_step: @authoring,
    remove_step: @authoring,
    reorder_steps: @authoring,
    assign_resource: @authoring,
    save_resource: @authoring,
    delete_resource: @authoring,
    discover_resource: @authoring,
    set_setting: @authoring,
    # Staging writes into the quarantine directory; loading approves that
    # file's code, per action.
    stage_skill: @authoring,
    load_skill: %{admin_ui: :code},
    unload_skill: @authoring,
    generate_skill: @authoring,
    save_provider: @authoring,
    save_policy: @authoring,
    save_node: @authoring,
    set_gateway_owner: @authoring,
    delete_memory: @authoring,
    # secrets
    set_secret: @authoring,
    clear_secret: @authoring,
    attach_login: @authoring,
    generate_mcp_key: @authoring,
    connect_google: @authoring,
    disconnect_google: @authoring,
    upgrade_secrets: %{system: :none},
    # identity. Setting the second factor up needs only the login (it is
    # refused while 2FA is on): requiring a second factor to configure the
    # second factor is the circle this design breaks.
    set_up_second_factor: %{admin_ui: :none},
    disable_second_factor: %{admin_ui: :code},
    regenerate_recovery_codes: %{admin_ui: :code},
    sign_out_everywhere: @authoring,
    # data
    download_database: @authoring,
    export_data: @authoring,
    export_workflow: @authoring,
    restore_data: %{admin_ui: :code},
    clear_run_history: @authoring,
    # runs
    run_workflow: %{admin_ui: :none, gateway: :none, mcp: :none, webhook: :none, system: :none},
    run_protected_workflow: %{admin_ui: :code, gateway: :code},
    run_skill: %{admin_ui: :none, gateway: :none, skill: :none, system: :none},
    run_privileged_skill: @authoring,
    # recordings
    record: @authoring,
    replay: @authoring
  }

  @typedoc "A named privileged action: a key of `catalogue/0`."
  @type action :: atom()

  @typedoc "Why `authorize/2` refused."
  @type denial :: :unknown_action | :entry_point_not_allowed | :second_factor_required

  @typedoc "Why a change was refused before it ran."
  @type refusal :: :not_elevated | :no_second_factor

  @typedoc "What a change returns: its result, or why it did not happen."
  @type write_result :: {:ok, term()} | {:error, term()}

  @doc """
  Make one control-plane change for the session `sid`, described by `detail`.

  `write` runs inside the transaction and returns `{:ok, result}` or
  `{:error, reason}`. `after_commit` receives the result once it is committed.

  Returns `{:ok, result}`, or `{:error, reason}` where reason is a refusal,
  `:audit_failed`, or whatever `write` returned.
  """
  @spec gated(String.t() | nil, String.t(), (-> write_result()), (term() -> term())) ::
          {:ok, term()} | {:error, refusal() | :audit_failed | term()}
  def gated(sid, detail, write, after_commit \\ fn _result -> :ok end) do
    with :ok <- permitted(Elevation.elevated?(sid), sid, detail),
         {:ok, result} <-
           transact(fn -> AuditLog.record_admin_write(print(sid), detail) end, write) do
      after_commit.(result)
      {:ok, result}
    end
  end

  @doc """
  Record what an effect outside the database did, with any database write
  that follows from it, as one transaction.

  Runs only after a `gated/4` change committed, so it asks for no elevation of
  its own: the decision was made and audited already.
  """
  @spec outcome(String.t() | nil, String.t(), (-> write_result())) ::
          {:ok, term()} | {:error, :audit_failed | term()}
  def outcome(sid, detail, write \\ fn -> {:ok, :recorded} end) do
    outcome_for(requester(sid), detail, write)
  end

  @typedoc """
  Who asked for a change, in the form that may cross into a task: the session
  by fingerprint — never the sid, which is a credential — and the principal.
  """
  @type requester :: %{session: String.t(), principal: String.t()}

  @doc "The requester for the session `sid`, to hand to work that outlives the call."
  @spec requester(String.t() | nil) :: requester()
  def requester(sid), do: %{session: print(sid), principal: Principal.current()}

  @doc "The requester for work nobody asked for from a session: a gateway command, a migration."
  @spec unattended() :: requester()
  def unattended, do: %{session: "unattended", principal: Principal.current()}

  @doc """
  `outcome/3` for a requester carried into a task, where the outcome is known
  long after the call that asked for it has returned.
  """
  @spec outcome_for(requester(), String.t(), (-> write_result())) ::
          {:ok, term()} | {:error, :audit_failed | term()}
  def outcome_for(%{session: session, principal: principal}, detail, write) do
    transact(fn -> AuditLog.record_admin_outcome(session, detail, principal) end, write)
  end

  @doc """
  Every privileged action: for each entry point that may ask for it, the
  proof it needs. An entry point not listed may not ask.
  """
  @spec catalogue() :: %{action() => %{Context.entry_point() => :none | :elevation | :code}}
  def catalogue, do: @catalogue

  @doc """
  Whether `context` may have `action`, by the catalogue. Pure: the proof is
  taken as `context` states it. A code does not stand in for an elevation,
  nor an elevation for a code.
  """
  @spec authorize(action(), Context.t()) :: :ok | {:error, denial()}
  def authorize(action, %Context{entry_point: entry_point, proof: proof}) do
    @catalogue
    |> Map.fetch(action)
    |> required(entry_point)
    |> satisfied(proof)
  end

  defp required(:error, _entry_point), do: {:error, :unknown_action}
  defp required({:ok, entry_points}, entry_point), do: Map.fetch(entry_points, entry_point)

  defp satisfied({:error, _reason} = unknown, _proof), do: unknown
  defp satisfied(:error, _proof), do: {:error, :entry_point_not_allowed}
  defp satisfied({:ok, :none}, _proof), do: :ok
  defp satisfied({:ok, proof}, proof), do: :ok
  defp satisfied({:ok, _needed}, _proof), do: {:error, :second_factor_required}

  @doc """
  Perform `action` with `params` for `context`: authorize it, run it, and
  audit the attempt whatever its outcome.

  `context` must come from one of `AlexClaw.ControlPlane.Context`'s
  constructors other than `new/3`; its proof is established here — the
  session's elevation read now, a code verified now. Returns what the action
  returned, a refusal (`t:denial/0`, `:unverified_context`, a code's
  refusal), or `{:error, :audit_failed}` when the row could not be written.
  """
  @spec perform(action(), map(), Context.t()) :: {:ok, term()} | {:error, term()}
  def perform(action, params, %Context{} = context) do
    case admitted(action, context) do
      {:ok, proven} -> run(Actions.kind(action), action, params, proven)
      {:error, reason} -> deny(action, params, context, reason)
    end
  end

  defp admitted(action, context) do
    with :ok <- verified(context),
         {:ok, proven} <- proven(context, action),
         :ok <- authorize(action, proven),
         :ok <- wired(Actions.wired?(action)),
         do: {:ok, proven}
  end

  defp wired(true), do: :ok
  defp wired(false), do: {:error, :not_wired}

  defp verified(%Context{verified: true}), do: :ok
  defp verified(%Context{}), do: {:error, :unverified_context}

  # A code is offered only to an action and entry point that call for one; it
  # is verified in the action's own transaction (`run/4`).
  defp proven(%Context{code: code} = context, action) when is_binary(code),
    do: {:ok, %{context | proof: code_proof(needs(action, context.entry_point))}}

  # The elevation is read again now: the window may have closed since the
  # context was built.
  defp proven(%Context{entry_point: :admin_ui, sid: sid}, _action),
    do: {:ok, Context.admin_ui(sid)}

  defp proven(context, _action), do: {:ok, context}

  defp needs(action, entry_point), do: get_in(@catalogue, [action, entry_point])

  defp code_proof(:code), do: :code
  defp code_proof(_needed), do: nil

  # A change for a code: the code is checked, the row written and the change
  # made in one transaction. A wrong code writes nothing but its own attempt
  # row (kept) and is refused; a row that cannot be written undoes the check
  # and the change alike — for :disable_second_factor, 2FA stays on.
  defp run(:change, action, params, %Context{code: code} = context) when is_binary(code) do
    reason = reason(action, params, context)

    committed =
      Repo.transaction(fn ->
        context.sid
        |> CodeEntry.verify_with(:web, Actions.verifier(action, code))
        |> checked(action, params, context, reason)
      end)

    coded(committed, action, params, context)
  end

  defp run(:change, action, params, context) do
    reason = reason(action, params, context)

    with {:ok, result} <-
           transact(
             fn -> audit(context, action, "write", reason) end,
             fn -> Actions.run(action, params) end
           ) do
      Actions.after_commit(action, params, result, context)
      {:ok, result}
    end
  end

  defp run(:effect, action, params, context) do
    reason = reason(action, params, context)

    case audit(context, action, "allow", reason) do
      :ok -> Actions.run(action, params)
      {:error, _reason} -> {:error, :audit_failed}
    end
  end

  defp checked(:ok, action, params, context, reason) do
    with {:audit, :ok} <- {:audit, audit(context, action, "write", reason)},
         {:ok, result} <- Actions.run(action, params) do
      {:done, result}
    else
      {:audit, {:error, _reason}} -> Repo.rollback(:audit_failed)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp checked({:error, why}, _action, _params, _context, _reason), do: {:refused, why}

  defp coded({:ok, {:done, result}}, action, params, context) do
    Actions.after_commit(action, params, result, context)
    {:ok, result}
  end

  defp coded({:ok, {:refused, why}}, action, params, context),
    do: deny(action, params, context, why)

  defp coded({:error, _reason} = failed, _action, _params, _context), do: failed

  defp audit(%Context{identity: identity, entry_point: entry_point}, action, decision, reason),
    do: AuditLog.record_action(identity, entry_point, action, decision, reason)

  defp deny(action, params, %Context{identity: identity, entry_point: entry_point} = context, why) do
    AuditLog.log_action_refusal(
      identity,
      entry_point,
      action,
      "#{why} — #{reason(action, params, context)}"
    )

    {:error, why}
  end

  defp reason(action, params, %Context{entry_point: entry_point}),
    do: "#{action} from #{entry_point}: #{Actions.describe(action, params)}"

  defp permitted(true, _sid, _detail), do: :ok
  defp permitted(false, sid, detail), do: refuse(Elevation.configured?(), sid, detail)

  defp refuse(true, sid, detail), do: refused(:not_elevated, sid, detail)
  defp refuse(false, sid, detail), do: refused(:no_second_factor, sid, detail)

  defp refused(reason, sid, detail) do
    AuditLog.log_admin_refusal(print(sid), reason, detail)
    {:error, reason}
  end

  defp transact(audit, write) do
    Repo.transaction(fn ->
      with {:audit, :ok} <- {:audit, audit.()},
           {:ok, result} <- write.() do
        result
      else
        {:audit, {:error, _reason}} -> Repo.rollback(:audit_failed)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp print(sid) when is_binary(sid), do: Elevation.fingerprint(sid)
  defp print(_sid), do: "unidentified"
end
