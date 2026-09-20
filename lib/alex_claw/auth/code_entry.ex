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

  defp totp_or_recovery(true, _code, sid, method), do: accept(sid, method, :totp)

  # Recovery codes are accepted in the browser and nowhere else. They are never
  # sent over a gateway, for the same reason they must not be typed into one: a
  # chat transcript is a durable copy of the way back in, sitting on someone
  # else's server. An operator whose authenticator is gone still has the admin
  # UI, which is where the codes are read and where they are spent.
  defp totp_or_recovery(false, code, sid, :web) do
    spent(RecoveryCodes.redeem(code), sid, :web)
  end

  defp totp_or_recovery(false, _code, sid, :gateway), do: reject(sid, :gateway)

  defp spent({:ok, _remaining}, sid, method), do: accept(sid, method, :recovery_code)
  defp spent({:error, :invalid_code}, sid, method), do: reject(sid, method)

  defp accept(sid, method, factor) do
    CodeAttempts.record_success(sid)
    AuditLog.log_code_attempt(:accepted, fingerprint(sid), method, factor)
    :ok
  end

  # A wrong code is reported as a wrong code, even when it is the one that trips
  # a lock. The lock is state the caller can read — the page shows it, and the
  # gateway path counts this attempt against the challenge — whereas conflating
  # the two would mean a caller could not tell "you guessed wrong" from "the
  # attempt never reached the verifier".
  defp reject(sid, method) do
    AuditLog.log_code_attempt(:refused, fingerprint(sid), method, :unknown)
    CodeAttempts.record_failure(sid)
    {:error, :invalid_code}
  end

  # Operators paste codes with the space their authenticator shows.
  defp normalize(code), do: code |> to_string() |> String.replace(~r/\s/, "")

  defp fingerprint(sid) when is_binary(sid), do: Elevation.fingerprint(sid)
  defp fingerprint(_sid), do: "unidentified"
end
