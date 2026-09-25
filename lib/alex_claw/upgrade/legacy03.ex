defmodule AlexClaw.Upgrade.Legacy03 do
  @moduledoc """
  Reads what AlexClaw 0.3.x stored encrypted under `SECRET_KEY_BASE`, for the
  boot upgrade and nothing else (`AlexClaw.Config.SecretUpgrade`).

  0.3.x wrote a sensitive value as `"enc:" <> base64(iv <> ciphertext <> tag)`,
  AES-256-GCM under a key derived from `SECRET_KEY_BASE` with HKDF-SHA256.
  Since 0.4.0 no value is stored that way: the upgrade moves each one into
  OpenBao, or, for a row designed to be safe at rest, back to its plain form.
  This module only decrypts; nothing in AlexClaw encrypts any more.

  Remove it in the release after 0.4.0, once 0.3.x can no longer upgrade
  directly (local-docs/BACKLOG.md).
  """

  @prefix "enc:"
  @iv_bytes 12
  @tag_bytes 16

  @doc "Whether `value` is a 0.3.x ciphertext."
  @spec ciphertext?(term()) :: boolean()
  def ciphertext?(@prefix <> _), do: true
  def ciphertext?(_value), do: false

  @doc """
  The plaintext of a 0.3.x ciphertext; any other value as it is. `{:error,
  :does_not_decrypt}` for a ciphertext made under another key, or damaged.
  """
  @spec decrypt(term()) :: {:ok, term()} | {:error, :does_not_decrypt}
  def decrypt(@prefix <> encoded), do: encoded |> Base.decode64() |> opened()
  def decrypt(value), do: {:ok, value}

  @doc "Every 0.3.x ciphertext in `value` (a map, a list or a string) decrypted."
  @spec decrypt_all(term()) :: {:ok, term()} | {:error, :does_not_decrypt}
  def decrypt_all(value) when is_map(value) do
    value
    |> Enum.reduce_while({:ok, %{}}, fn {k, v}, {:ok, acc} ->
      v |> decrypt_all() |> collected(&Map.put(acc, k, &1))
    end)
  end

  def decrypt_all(value) when is_list(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn v, {:ok, acc} ->
      v |> decrypt_all() |> collected(&[&1 | acc])
    end)
    |> reversed()
  end

  def decrypt_all(value), do: decrypt(value)

  defp collected({:ok, plain}, add), do: {:cont, {:ok, add.(plain)}}
  defp collected(error, _add), do: {:halt, error}

  defp reversed({:ok, list}), do: {:ok, Enum.reverse(list)}
  defp reversed(error), do: error

  defp opened({:ok, raw}) when byte_size(raw) >= @iv_bytes + @tag_bytes do
    size = byte_size(raw) - @iv_bytes - @tag_bytes

    <<iv::binary-size(@iv_bytes), ciphertext::binary-size(size), tag::binary-size(@tag_bytes)>> =
      raw

    :aes_256_gcm
    |> :crypto.crypto_one_time_aead(key(), iv, ciphertext, <<>>, tag, false)
    |> plaintext()
  end

  defp opened(_malformed), do: {:error, :does_not_decrypt}

  defp plaintext(:error), do: {:error, :does_not_decrypt}
  defp plaintext(plaintext) when is_binary(plaintext), do: {:ok, plaintext}

  defp key do
    secret_key_base =
      :alex_claw
      |> Application.fetch_env!(AlexClawWeb.Endpoint)
      |> Keyword.fetch!(:secret_key_base)

    prk = :crypto.mac(:hmac, :sha256, <<0::256>>, secret_key_base)
    binary_part(:crypto.mac(:hmac, :sha256, prk, <<"AlexClaw.Config.Crypto", 1>>), 0, 32)
  end
end
