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

  alias AlexClaw.Auth.{AuditLog, CodeAttempts, Elevation, RecoveryCodes, TOTP}

  @type method :: :web | :gateway
  @type failure :: :locked_session | :locked_instance | :invalid_code | :not_configured

  @doc """
  Check `code` for `sid`, counting the attempt.

  The code may be from the authenticator or one of the recovery codes; the
  caller does not choose, because the operator reaching for a recovery code has
  already lost the thing that would have told them which field to use.

  Returns `:ok`, or the reason it was refused. A refusal that is a lock names
  the lock, because "wrong code" and "stop typing for fifteen minutes" are
  different things to tell an operator.
  """
  @spec verify(String.t() | nil, String.t(), method()) :: :ok | {:error, failure()}
  def verify(sid, code, method \\ :web) do
    with :ok <- configured(TOTP.enabled?()),
         :ok <- allowed(CodeAttempts.status(sid)) do
      check(normalize(code), sid, method)
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

  # A code is a TOTP code or a recovery code, and the field does not ask which:
  # an operator whose phone is gone types what they have, in the same box.
  defp check(code, sid, method) do
    totp_or_recovery(TOTP.verify(code), code, sid, method)
  end

  defp totp_or_recovery(true, _code, sid, method), do: accept(sid, method)

  defp totp_or_recovery(false, code, sid, method) do
    spent(RecoveryCodes.redeem(code), sid, method)
  end

  defp spent({:ok, _remaining}, sid, method), do: accept(sid, method)
  defp spent({:error, :invalid_code}, sid, method), do: reject(sid, method)

  defp accept(sid, method) do
    CodeAttempts.record_success(sid)
    AuditLog.log_code_attempt(:accepted, fingerprint(sid), method)
    :ok
  end

  defp reject(sid, method) do
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
