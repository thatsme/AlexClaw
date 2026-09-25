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

  alias AlexClaw.Auth.{AuditLog, CodeAttempts, Elevation, SecondFactor, Sessions}

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
    verify_with(sid, method, fn -> SecondFactor.impl().verify(code, method) end)
  end

  @doc """
  `verify/3` with the verification done by `verifier`, for an action that
  checks the code itself (turning the second factor off): the same limits,
  audit row and refusals, and the code verified exactly once. `verifier`
  returns `{:ok, factor}` or `{:error, :invalid_code}`.
  """
  @spec verify_with(String.t() | nil, :web | :gateway, (-> {:ok, atom()} | {:error, :invalid_code})) ::
          :ok | {:error, atom()}
  def verify_with(sid, method, verifier) do
    with :ok <- configured(SecondFactor.impl().configured?()),
         :ok <- allowed(CodeAttempts.status(sid)) do
      judge(verifier.(), sid, method)
    end
  end

  # --- Internals ---

  defp configured(true), do: :ok
  defp configured(false), do: {:error, :not_configured}

  defp allowed(:ok), do: :ok
  defp allowed({:locked, :session, _until}), do: {:error, :locked_session}
  defp allowed({:locked, :instance, _until}), do: {:error, :locked_instance}

  # What "a good code" means belongs to the second-factor implementation (or to
  # the action that verifies it). What belongs here is everything around it: the
  # limits, the audit row, and the refusal an operator reads.
  defp judge({:ok, factor}, sid, method), do: accept(sid, method, factor)
  defp judge({:error, :invalid_code}, sid, method), do: reject(sid, method)

  defp accept(sid, method, factor) do
    CodeAttempts.record_success(sid)
    AuditLog.log_code_attempt(:accepted, fingerprint(sid), method, factor)
    accepted(factor, sid)
  end

  # A recovery code is what an operator reaches for when the authenticator is
  # gone — lost, or in someone else's hands. Any other login may be that someone,
  # so every login except the one that just proved itself is ended.
  defp accepted(:recovery_code, sid) do
    {:ok, _closed} = Sessions.close_others(sid, "recovery code redeemed")
    :ok
  end

  defp accepted(_factor, _sid), do: :ok

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

  defp fingerprint(sid) when is_binary(sid), do: Elevation.fingerprint(sid)
  defp fingerprint(_sid), do: "unidentified"
end
