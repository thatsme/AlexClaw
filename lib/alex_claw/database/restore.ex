defmodule AlexClaw.Database.Restore do
  @moduledoc """
  Restoring the database from the admin UI — disabled.

  Restore is an operator procedure until 0.3.34, which brings a restore that
  loads data rather than running a file. Every path that could start one —
  the Database page, and a restore challenge raised before this release and
  answered after it — ends here, is refused, and is audited as refused.

  An operator restores with the database owner's credentials, from the host:

      docker exec -i alexclaw-db-prod \\
        psql -U <owner> -d alex_claw_prod --single-transaction < backup.sql
  """

  alias AlexClaw.Auth.AuditLog

  @refusal "Restore is an operator procedure until 0.3.34."

  @doc "The message every refused restore answers with."
  @spec refusal() :: String.t()
  def refusal, do: @refusal

  @doc """
  Refuse a restore, record the refusal, and discard any staged file.

  `context` names the upload and, by fingerprint, the session that asked.
  """
  @spec run(Path.t(), %{filename: String.t(), session: String.t()}) :: {:error, String.t()}
  def run(path, %{filename: filename, session: session}) do
    discard(path)
    AuditLog.log_admin_refusal(session, :disabled, "database restore from #{filename}")
    {:error, @refusal}
  end

  @doc "Discard a staged file. A file that is already gone is not an error."
  @spec discard(Path.t()) :: :ok
  def discard(path) do
    File.rm(path)
    :ok
  end
end
