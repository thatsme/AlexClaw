defmodule AlexClaw.Encrypted do
  @moduledoc """
  Credentials stored outside the settings, encrypted at rest under the key
  derived from `SECRET_KEY_BASE` (`AlexClaw.Config.Crypto`), the same as the
  sensitive settings.

  Every string in a sealed value is stored as `enc:<ciphertext>`; maps and
  lists keep their shape, so a JSON column still reads as the object it is,
  with its secrets unreadable. `nil` and empty strings stay as they are.

  The Ecto types that apply it:

    * `AlexClaw.Encrypted.Text` — a whole text column (`llm_providers.api_key`)
    * `AlexClaw.Encrypted.Map` — a whole JSON column (`llm_providers.headers`)
    * `AlexClaw.Encrypted.StepConfig` — the keys of a step's `config` that a
      skill declares secret with `c:AlexClaw.Skill.secret_config_keys/0`

  A stored value that does not decrypt raises: a credential that cannot be
  read is a misconfigured key, not something to carry on without.
  """

  alias AlexClaw.Config.Crypto

  @doc "Encrypt every non-empty string in `value`, keeping maps and lists as they are."
  @spec seal(term()) :: term()
  def seal(value) when value in [nil, ""], do: value
  def seal(value) when is_binary(value), do: Crypto.encrypt!(value)
  def seal(value) when is_map(value), do: Map.new(value, fn {k, v} -> {k, seal(v)} end)
  def seal(value) when is_list(value), do: Enum.map(value, &seal/1)
  def seal(value), do: value

  @doc """
  Like `seal/1`, but a string already encrypted is left as it is — for values
  read raw from the database, where `enc:` is ciphertext rather than input.
  """
  @spec seal_plaintext(term()) :: term()
  def seal_plaintext("enc:" <> _ = value), do: value

  def seal_plaintext(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {k, seal_plaintext(v)} end)

  def seal_plaintext(value) when is_list(value), do: Enum.map(value, &seal_plaintext/1)
  def seal_plaintext(value), do: seal(value)

  @doc "Decrypt every `enc:` string in `value`. Raises on one that does not decrypt."
  @spec open!(term()) :: term()
  def open!("enc:" <> _ = value), do: decrypted!(Crypto.decrypt(value))
  def open!(value) when is_map(value), do: Map.new(value, fn {k, v} -> {k, open!(v)} end)
  def open!(value) when is_list(value), do: Enum.map(value, &open!/1)
  def open!(value), do: value

  @doc "Whether `value` holds a string that is not encrypted."
  @spec plaintext?(term()) :: boolean()
  def plaintext?(value) when value in [nil, ""], do: false
  def plaintext?("enc:" <> _), do: false
  def plaintext?(value) when is_binary(value), do: true
  def plaintext?(value) when is_map(value), do: Enum.any?(value, fn {_k, v} -> plaintext?(v) end)
  def plaintext?(value) when is_list(value), do: Enum.any?(value, &plaintext?/1)
  def plaintext?(_value), do: false

  @doc "Every `enc:` string in `value` decrypts under the running key."
  @spec decryptable?(term()) :: boolean()
  def decryptable?("enc:" <> _ = value), do: match?({:ok, _}, Crypto.decrypt(value))

  def decryptable?(value) when is_map(value),
    do: Enum.all?(value, fn {_k, v} -> decryptable?(v) end)

  def decryptable?(value) when is_list(value), do: Enum.all?(value, &decryptable?/1)
  def decryptable?(_value), do: true

  @doc """
  Every `enc:` string in `value` decrypted under `old` and encrypted under
  `new`, each checked to decrypt again. Answers the value and how many strings
  moved, or `:error` if one does not decrypt under `old`.
  """
  @spec rekey(term(), binary(), binary()) :: {:ok, term(), non_neg_integer()} | :error
  def rekey("enc:" <> _ = value, old, new) do
    with {:ok, plaintext} <- Crypto.decrypt_with(old, value),
         {:ok, ciphertext} <- Crypto.encrypt_with(new, plaintext),
         {:ok, ^plaintext} <- Crypto.decrypt_with(new, ciphertext) do
      {:ok, ciphertext, 1}
    else
      _ -> :error
    end
  end

  def rekey(value, old, new) when is_map(value) do
    value
    |> Enum.reduce_while({:ok, [], 0}, fn {k, v}, acc ->
      rekey_into(acc, k, rekey(v, old, new))
    end)
    |> rekeyed(&Map.new/1)
  end

  def rekey(value, old, new) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], 0}, fn {v, i}, acc ->
      rekey_into(acc, i, rekey(v, old, new))
    end)
    |> rekeyed(fn pairs -> pairs |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1)) end)
  end

  def rekey(value, _old, _new), do: {:ok, value, 0}

  defp rekey_into({:ok, pairs, n}, k, {:ok, v, m}), do: {:cont, {:ok, [{k, v} | pairs], n + m}}
  defp rekey_into(_acc, _k, :error), do: {:halt, :error}

  defp rekeyed({:ok, pairs, n}, build), do: {:ok, build.(pairs), n}
  defp rekeyed(:error, _build), do: :error

  defp decrypted!({:ok, plaintext}), do: plaintext

  defp decrypted!({:error, _reason}),
    do: raise("a stored credential does not decrypt under this SECRET_KEY_BASE")
end
