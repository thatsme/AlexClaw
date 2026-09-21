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
  """

  alias AlexClaw.Auth.{AuditLog, Elevation}
  alias AlexClaw.Repo

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
    transact(fn -> AuditLog.record_admin_outcome(print(sid), detail) end, write)
  end

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
