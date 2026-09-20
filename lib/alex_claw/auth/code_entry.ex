defmodule AlexClaw.Auth.CodeEntry do
  @moduledoc """
  One place a second-factor code is checked, however it arrived.

  The second factor is the authenticator app. A gateway is a convenient place
  to type the code, never what makes it a second factor — so the same code, the
  same replay guard and the same brute-force limits apply whether it was typed
  into the admin UI or sent to a bot.

  Every attempt is audited with the method it came in by and the session that
  made it, because "who tried and failed" is the question this record exists to
  answer.
  """

  alias AlexClaw.Auth.{AuditLog, CodeAttempts, Elevation, TOTP}

  @type method :: :web | :gateway
  @type failure :: :locked_session | :locked_instance | :invalid_code | :not_configured

  @doc """
  Check `code` for `sid`, counting the attempt.

  Returns `:ok`, or the reason it was refused. A refusal that is a lock names
  the lock, because "wrong code" and "stop typing for fifteen minutes" are
  different things to tell an operator.
  """
  @spec verify(String.t() | nil, String.t(), method()) :: :ok | {:error, failure()}
  def verify(sid, code, method \\ :web) do
    with :ok <- configured(TOTP.enabled?()),
         :ok <- allowed(CodeAttempts.status(sid)) do
      judge(TOTP.verify(normalize(code)), sid, method)
    end
  end

  @doc "Record a code accepted somewhere other than here, for the same audit trail."
  @spec accepted_elsewhere(String.t() | nil, method()) :: :ok
  def accepted_elsewhere(sid, method) do
    AuditLog.log_code_attempt(:accepted, fingerprint(sid), method)
  end

  @doc "Record a code refused somewhere other than here."
  @spec refused_elsewhere(String.t() | nil, method()) :: :ok
  def refused_elsewhere(sid, method) do
    AuditLog.log_code_attempt(:refused, fingerprint(sid), method)
  end

  # --- Internals ---

  defp configured(true), do: :ok
  defp configured(false), do: {:error, :not_configured}

  defp allowed(:ok), do: :ok
  defp allowed({:locked, :session, _until}), do: {:error, :locked_session}
  defp allowed({:locked, :instance, _until}), do: {:error, :locked_instance}

  defp judge(true, sid, method) do
    CodeAttempts.record_success(sid)
    AuditLog.log_code_attempt(:accepted, fingerprint(sid), method)
    :ok
  end

  defp judge(false, sid, method) do
    AuditLog.log_code_attempt(:refused, fingerprint(sid), method)
    refusal(CodeAttempts.record_failure(sid))
  end

  defp refusal({:locked, :session, _until}), do: {:error, :locked_session}
  defp refusal({:locked, :instance, _until}), do: {:error, :locked_instance}
  defp refusal(:ok), do: {:error, :invalid_code}

  # Operators paste codes with the space their authenticator shows.
  defp normalize(code), do: code |> to_string() |> String.replace(~r/\s/, "")

  defp fingerprint(sid) when is_binary(sid), do: Elevation.fingerprint(sid)
  defp fingerprint(_sid), do: "unidentified"
end
