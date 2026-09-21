defmodule AlexClaw.Config.Rekey do
  @moduledoc """
  Move everything encrypted under one SECRET_KEY_BASE to another.

  Sensitive settings are stored encrypted (`AlexClaw.Config.Crypto`) with a key
  derived from SECRET_KEY_BASE — the TOTP secret among them. Changing
  SECRET_KEY_BASE without this would leave every such value unreadable: 2FA
  would stop working, and every stored credential with it.

  `run/2` does it as one transaction: every encrypted setting is decrypted with
  the old key, re-encrypted with the new one and checked to decrypt again, and
  written back, with an audit row saying so. A value the old key cannot decrypt
  stops the whole run with nothing changed — including a second run, after
  which the old key decrypts nothing. Every login is also ended: each one is
  bound to a fingerprint keyed by the old SECRET_KEY_BASE, and could not be
  used again anyway.

  The application must be stopped while this runs. A running node holds the
  old key in memory and would go on reading and writing with it.
  """

  import Ecto.Query

  alias AlexClaw.Auth.{AdminSession, AuditLog}
  alias AlexClaw.Config.{Crypto, Setting}
  alias AlexClaw.Repo

  @doc """
  Re-encrypt every encrypted setting from `old_secret` to `new_secret`, the two
  SECRET_KEY_BASE values. Answers how many values moved.
  """
  @spec run(String.t(), String.t()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def run(old_secret, new_secret) when old_secret == new_secret,
    do: {:error, "The old and new SECRET_KEY_BASE are the same"}

  def run(old_secret, new_secret) do
    old = Crypto.key_for(old_secret)
    new = Crypto.key_for(new_secret)

    Repo.transaction(fn ->
      settings = Repo.all(from(s in Setting, where: like(s.value, "enc:%"), lock: "FOR UPDATE"))

      with {:ok, moved} <- rekeyed(settings, old, new),
           :ok <- write(moved),
           {sessions, _} <- Repo.delete_all(AdminSession),
           :ok <- audit(length(moved), sessions) do
        length(moved)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp rekeyed(settings, old, new) do
    Enum.reduce_while(settings, {:ok, []}, fn setting, {:ok, acc} ->
      case rekey(setting, old, new) do
        {:ok, value} -> {:cont, {:ok, [{setting, value} | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp rekey(setting, old, new) do
    with {:ok, plaintext} <- decrypted(Crypto.decrypt_with(old, setting.value), setting),
         {:ok, ciphertext} <- Crypto.encrypt_with(new, plaintext) do
      verified(Crypto.decrypt_with(new, ciphertext), plaintext, ciphertext, setting)
    end
  end

  # The new ciphertext must decrypt back to the same value before it is written.
  defp verified({:ok, plaintext}, plaintext, ciphertext, _setting), do: {:ok, ciphertext}

  defp verified(_result, _plaintext, _ciphertext, setting),
    do: {:error, "#{setting.key} did not survive re-encryption — nothing was changed"}

  defp decrypted({:ok, plaintext}, _setting), do: {:ok, plaintext}

  defp decrypted({:error, _reason}, setting) do
    {:error,
     "#{setting.key} cannot be decrypted with the old SECRET_KEY_BASE — nothing was changed"}
  end

  defp write(moved) do
    Enum.each(moved, fn {setting, value} ->
      Repo.update_all(from(s in Setting, where: s.id == ^setting.id), set: [value: value])
    end)
  end

  defp audit(count, sessions) do
    "operator"
    |> AuditLog.record_admin_write(
      "SECRET_KEY_BASE rotated: #{count} encrypted settings re-encrypted, #{sessions} logins ended"
    )
    |> audited()
  end

  defp audited(:ok), do: :ok

  defp audited({:error, _reason}),
    do: {:error, "the audit row could not be written — nothing was changed"}
end
