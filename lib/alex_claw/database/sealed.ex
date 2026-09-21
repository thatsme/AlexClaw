defmodule AlexClaw.Database.Sealed do
  @moduledoc """
  Credentials stored in plain columns, encrypted in an export and decrypted by
  a restore. An export file then carries no credential in clear, the same as
  the encrypted settings it already holds.

  Sealing uses the key derived from `SECRET_KEY_BASE`, so an export restores
  only under the key it was written with. A file whose sealed values do not
  decrypt is refused before anything changes.

  A column is sealed whole, or only at named keys of its JSON object. Values
  that are `nil` or empty stay as they are. Settings are encrypted already;
  a restore only checks that each encrypted one decrypts, so a file from
  another key cannot leave the TOTP secret unreadable.
  """

  alias AlexClaw.Config.Crypto

  @sealed %{
    {"llm_providers", "api_key"} => :whole,
    {"llm_providers", "headers"} => :whole,
    {"workflow_steps", "config"} => {:keys, ["bot_token"]},
    {"settings", "value"} => :encrypted
  }

  @doc "The sealed columns: `{table, column} => :whole | {:keys, [key]}`."
  @spec columns() :: %{{String.t(), String.t()} => :whole | :encrypted | {:keys, [String.t()]}}
  def columns, do: @sealed

  @doc "A function sealing one exported row of `table`, whose columns are `names`."
  @spec sealer(String.t(), [String.t()]) :: ([String.t() | nil] -> [String.t() | nil])
  def sealer(table, names) do
    rules = rules(table, names)
    fn row -> Enum.map(Enum.zip(row, rules), fn {value, rule} -> seal(value, rule) end) end
  end

  @doc "Decrypt the sealed values in a restored row of `table`, whose columns are `names`."
  @spec unseal(String.t(), [String.t()], [String.t() | nil]) ::
          {:ok, [String.t() | nil]} | {:error, String.t()}
  def unseal(table, names, row) do
    row
    |> Enum.zip(rules(table, names))
    |> Enum.reduce_while({:ok, []}, fn {value, rule}, {:ok, acc} ->
      opened(unseal_value(value, rule), acc)
    end)
    |> reversed()
  end

  defp rules(table, names), do: Enum.map(names, &Map.get(@sealed, {table, &1}))

  defp seal(value, _rule) when value in [nil, ""], do: value
  defp seal(value, nil), do: value
  defp seal(value, :whole), do: Crypto.encrypt!(value)
  defp seal(value, :encrypted), do: value

  defp seal(value, {:keys, keys}), do: seal_keys(Jason.decode!(value), value, keys)

  # Only a JSON object has keys to seal; anything else is written as it is.
  defp seal_keys(map, _value, keys) when is_map(map) do
    map
    |> Map.new(fn {key, v} -> {key, seal_key(key in keys, v)} end)
    |> Jason.encode!()
  end

  defp seal_keys(_decoded, value, _keys), do: value

  defp seal_key(true, v) when is_binary(v) and v != "", do: Crypto.encrypt!(v)
  defp seal_key(_sealed, v), do: v

  defp unseal_value(value, _rule) when value in [nil, ""], do: {:ok, value}
  defp unseal_value(value, nil), do: {:ok, value}
  defp unseal_value(value, :whole), do: Crypto.decrypt(value)
  defp unseal_value(value, :encrypted), do: value |> Crypto.decrypt() |> kept_as(value)

  defp unseal_value(value, {:keys, keys}), do: value |> Jason.decode() |> unseal_json(value, keys)

  defp unseal_json({:ok, map}, _value, keys) when is_map(map) do
    with {:ok, opened} <- unseal_keys(map, keys), do: {:ok, Jason.encode!(opened)}
  end

  # Not an object: nothing was sealed. The column's own type checks it.
  defp unseal_json(_decoded, value, _keys), do: {:ok, value}

  defp kept_as({:ok, _plaintext}, value), do: {:ok, value}
  defp kept_as(error, _value), do: error

  defp unseal_keys(map, keys) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, v}, {:ok, acc} ->
      kept(key, unseal_key(key in keys, v), acc)
    end)
  end

  defp kept(key, {:ok, v}, acc), do: {:cont, {:ok, Map.put(acc, key, v)}}
  defp kept(_key, error, _acc), do: {:halt, error}

  defp unseal_key(true, v) when is_binary(v), do: Crypto.decrypt(v)
  defp unseal_key(_sealed, v), do: {:ok, v}

  defp opened({:ok, value}, acc), do: {:cont, {:ok, [value | acc]}}
  defp opened({:error, _reason}, _acc), do: {:halt, :error}

  defp reversed({:ok, row}), do: {:ok, Enum.reverse(row)}

  defp reversed(:error),
    do: {:error, "a sealed value does not decrypt under this SECRET_KEY_BASE"}
end
