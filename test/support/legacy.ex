defmodule AlexClawTest.Legacy do
  @moduledoc """
  Settings rows as AlexClaw 0.3.x wrote them, for testing the upgrade.

  0.3.x stored every setting in the settings table through `Config.persist/3`:
  a sensitive setting's value encrypted with `AlexClaw.Config.Crypto` (AES-256-GCM
  under a key derived from `SECRET_KEY_BASE`, stored as `"enc:" <> base64`), any
  other setting's value as plain text. The current `Config` API routes a secret
  setting to OpenBao, so these helpers write and read the row directly, below
  that routing.
  """
  alias AlexClaw.Config.{Crypto, Setting}
  alias AlexClaw.Repo

  @doc """
  Write `key` = `value` as 0.3.x did: `encrypted: true` for a sensitive setting
  (the value encrypted, `sensitive: true`), `false` for a plain one. Replaces
  the row if there is one.
  """
  @spec insert_setting(String.t(), String.t(), keyword()) :: Setting.t()
  def insert_setting(key, value, opts) do
    encrypted = Keyword.fetch!(opts, :encrypted)

    %Setting{}
    |> Setting.changeset(%{
      key: key,
      value: stored(value, encrypted),
      type: "string",
      category: key |> String.split(".") |> hd(),
      sensitive: encrypted
    })
    |> Repo.insert!(on_conflict: {:replace, [:value, :sensitive]}, conflict_target: :key)
  end

  @doc "The row's value for `key`, decrypted as 0.3.x read it; nil when there is no row."
  @spec decrypt_setting(String.t()) :: String.t() | nil
  def decrypt_setting(key) do
    case Repo.get_by(Setting, key: key) do
      nil ->
        nil

      %Setting{value: value} ->
        {:ok, plaintext} = Crypto.decrypt(value)
        plaintext
    end
  end

  defp stored(value, true), do: Crypto.encrypt!(value)
  defp stored(value, false), do: value
end
