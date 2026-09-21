defmodule AlexClaw.Database.Restore do
  @moduledoc """
  Running an uploaded SQL file against the live database.

  This is the widest write the admin UI offers — arbitrary SQL as the
  application's own database user, which reaches the settings and policy tables
  without going through either. It is therefore challenged per action rather
  than covered by an elevation window: a fifteen-minute unlock earned for
  editing a setting must not also authorise a restore.

  The file is staged on disk between the upload and the verified code, because
  the code arrives on a gateway seconds or minutes later. Staged files are
  deleted whether the restore runs or not.
  """
  require Logger

  alias AlexClaw.Auth.{AuditLog, Principal}

  @staging_prefix "alexclaw-restore-"

  @doc """
  Copy an uploaded file somewhere it will survive until the code is answered.

  Returns the staged path.
  """
  @spec stage(Path.t()) :: {:ok, Path.t()} | {:error, File.posix()}
  def stage(uploaded_path) do
    staged = Path.join(System.tmp_dir!(), @staging_prefix <> token() <> ".sql")

    with :ok <- File.cp(uploaded_path, staged), do: {:ok, staged}
  end

  @doc "Discard a staged file — on refusal, or once the restore is done."
  @spec discard(Path.t()) :: :ok
  def discard(path) do
    File.rm(path)
    :ok
  end

  @doc """
  Run a staged file against the database, then discard it.

  Audited on both sides. The row saying a restore is starting is written
  before anything runs, and a restore whose row cannot be written does not
  run. The row saying how it ended is written after — a restore cannot be
  rolled back, so its outcome is recorded rather than made conditional.

  `context` names the upload and, by fingerprint, the session that asked.

  The file is consumed either way: a restore that failed halfway is not a file
  worth keeping around, and it holds whatever the uploader put in it.
  """
  @spec run(Path.t(), %{filename: String.t(), session: String.t()}) ::
          {:ok, String.t()} | {:error, String.t()}
  def run(path, %{filename: filename, session: session}) do
    detail = "database restore from #{filename}"

    session
    |> AuditLog.record_admin_write(detail)
    |> restore(path, session, detail)
  end

  defp restore(:ok, path, session, detail) do
    result = psql(File.exists?(path), path)
    discard(path)
    AuditLog.record_admin_outcome(session, "#{detail} — #{outcome(result)}", Principal.current())
    result
  end

  defp restore({:error, _reason}, path, _session, _detail) do
    discard(path)
    {:error, "The restore was not run: it could not be recorded in the audit log."}
  end

  defp outcome({:ok, message}), do: message
  defp outcome({:error, message}), do: message

  defp psql(false, path) do
    Logger.warning("Restore asked for a staged file that is gone: #{path}")
    {:error, "The uploaded file is no longer available — upload it again"}
  end

  defp psql(true, path) do
    db = connection_env()

    args = [
      "-h",
      db.hostname,
      "-U",
      db.username,
      "-d",
      db.database,
      "--single-transaction",
      "-f",
      path
    ]

    "psql"
    |> System.cmd(args, env: [{"PGPASSWORD", db.password}], stderr_to_stdout: true)
    |> report()
  end

  defp report({output, 0}) do
    {:ok,
     "Restore completed (#{length(String.split(output, "\n", trim: true))} statements executed)"}
  end

  defp report({error, _code}), do: {:error, "Restore failed: #{String.slice(error, 0, 500)}"}

  defp connection_env do
    %{
      hostname: System.get_env("DATABASE_HOSTNAME", "db"),
      username: System.get_env("DATABASE_USERNAME", "alexclaw"),
      password: System.get_env("DATABASE_PASSWORD", ""),
      database: "alex_claw_prod"
    }
  end

  defp token, do: 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
