defmodule AlexClaw.Config.Crypto do
  @moduledoc """
  AES-256-GCM encryption for sensitive config values.
  Uses SECRET_KEY_BASE as key material via HKDF derivation.
  """

  @iv_bytes 12
  @tag_bytes 16
  @prefix "enc:"

  @spec encrypt(String.t()) :: {:ok, String.t()} | {:error, term()}
  def encrypt(""), do: {:ok, ""}

  def encrypt(plaintext) when is_binary(plaintext) do
    key = derive_key()
    iv = :crypto.strong_rand_bytes(@iv_bytes)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, <<>>, @tag_bytes, true)

    encoded = Base.encode64(iv <> ciphertext <> tag)
    {:ok, @prefix <> encoded}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @spec encrypt!(String.t()) :: String.t()
  def encrypt!(plaintext) do
    case encrypt(plaintext) do
      {:ok, result} -> result
      {:error, reason} -> raise "Encryption failed: #{reason}"
    end
  end

  @spec decrypt(String.t()) :: {:ok, String.t()} | {:error, term()}
  def decrypt(@prefix <> encoded) do
    key = derive_key()

    with {:ok, raw} <- Base.decode64(encoded) do
      raw_size = byte_size(raw)

      if raw_size < @iv_bytes + @tag_bytes do
        {:error, :invalid_ciphertext}
      else
        ct_size = raw_size - @iv_bytes - @tag_bytes
        <<iv::binary-size(@iv_bytes), ciphertext::binary-size(ct_size), tag::binary-size(@tag_bytes)>> = raw

        case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, <<>>, tag, false) do
          plaintext when is_binary(plaintext) -> {:ok, plaintext}
          :error -> {:error, :decryption_failed}
        end
      end
    else
      :error -> {:error, :invalid_base64}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def decrypt(plaintext) when is_binary(plaintext), do: {:ok, plaintext}
  def decrypt(nil), do: {:ok, nil}

  @spec encrypted?(String.t() | nil) :: boolean()
  def encrypted?(@prefix <> _), do: true
  def encrypted?(_), do: false

  @spec derive_key() :: binary()
  def derive_key do
    case :persistent_term.get({__MODULE__, :key}, nil) do
      nil ->
        secret = fetch_secret_key_base!()
        key = hkdf_sha256(secret, "AlexClaw.Config.Crypto", 32)
        :persistent_term.put({__MODULE__, :key}, key)
        key

      key ->
        key
    end
  end

  defp fetch_secret_key_base! do
    case Application.get_env(:alex_claw, AlexClawWeb.Endpoint)[:secret_key_base] do
      nil -> raise "SECRET_KEY_BASE not configured"
      secret when byte_size(secret) < 32 -> raise "SECRET_KEY_BASE too short (need >= 32 bytes)"
      secret -> secret
    end
  end

  # HKDF-SHA256 extract-and-expand (RFC 5869)
  defp hkdf_sha256(ikm, info, length) do
    # Extract
    prk = :crypto.mac(:hmac, :sha256, <<0::256>>, ikm)
    # Expand (single block is enough for 32-byte output)
    :crypto.mac(:hmac, :sha256, prk, <<info::binary, 1>>)
    |> binary_part(0, length)
  end
end
