defmodule AlexClaw.Database.Sealed do
  @moduledoc """
  Credentials stored in plain columns, encrypted in an export and decrypted by
  a restore. An export file then carries no credential in clear, the same as
  the encrypted settings it already holds.

  Every string in a sealed value becomes `enc:<ciphertext>`; a JSON column
  keeps its shape, with its secrets unreadable. This is the form later
  releases store these credentials in at rest, so their restore reads this
  release's exports unchanged.

  Sealed: `llm_providers.api_key`, every string in `llm_providers.headers`,
  and the step config keys `bot_token` (Telegram Notify) and `headers` (API
  Request). `nil` and empty strings stay as they are.

  Sealing uses the key derived from `SECRET_KEY_BASE`, so an export restores
  only under the key it was written with. A file whose sealed or encrypted
  values do not decrypt is refused before anything changes. Settings are
  encrypted already; a restore only checks that each encrypted one decrypts,
  so a file from another key cannot leave the TOTP secret unreadable.
  """

  alias AlexClaw.Config.Crypto

  @sealed %{
    {"llm_providers", "api_key"} => :text,
    {"llm_providers", "headers"} => :json,
    {"workflow_steps", "config"} => {:json_keys, ["bot_token", "headers"]},
    {"settings", "value"} => :encrypted
  }

  @doc "The sealed columns and how each is sealed."
  @spec columns() :: %{
          {String.t(), String.t()} => :text | :json | :encrypted | {:json_keys, [String.t()]}
        }
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
    |> Enum.map(fn {value, rule} -> unseal_value(value, rule) end)
    |> collected()
  end

  defp rules(table, names), do: Enum.map(names, &Map.get(@sealed, {table, &1}))

  # --- Export ---

  defp seal(value, rule) when value in [nil, ""] or rule in [nil, :encrypted], do: value
  defp seal(value, :text), do: seal_strings(value)
  defp seal(value, :json), do: value |> Jason.decode!() |> seal_strings() |> Jason.encode!()

  defp seal(value, {:json_keys, keys}),
    do: value |> Jason.decode!() |> at_keys(keys, &seal_strings/1) |> Jason.encode!()

  defp seal_strings(value) when value in [nil, ""], do: value
  defp seal_strings(value) when is_binary(value), do: Crypto.encrypt!(value)

  defp seal_strings(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {k, seal_strings(v)} end)

  defp seal_strings(value) when is_list(value), do: Enum.map(value, &seal_strings/1)
  defp seal_strings(value), do: value

  defp at_keys(map, keys, fun) when is_map(map),
    do: Map.merge(map, map |> Map.take(keys) |> Map.new(fn {k, v} -> {k, fun.(v)} end))

  defp at_keys(other, _keys, _fun), do: other

  # --- Restore ---

  defp unseal_value(value, rule) when value in [nil, ""] or rule == nil, do: {:ok, value}
  defp unseal_value(value, :encrypted), do: value |> opens?() |> kept(value)
  defp unseal_value(value, :text), do: opened(value)

  defp unseal_value(value, :json) do
    with {:ok, decoded} <- Jason.decode(value), {:ok, opened} <- opened(decoded) do
      {:ok, Jason.encode!(opened)}
    else
      _ -> :error
    end
  end

  defp unseal_value(value, {:json_keys, keys}) do
    with {:ok, decoded} <- Jason.decode(value),
         {:ok, opened} <- opened_at_keys(decoded, keys) do
      {:ok, Jason.encode!(opened)}
    else
      _ -> :error
    end
  end

  defp opened_at_keys(map, keys) when is_map(map),
    do: map |> Map.take(keys) |> opened() |> ok_map(&Map.merge(map, &1))

  defp opened_at_keys(other, _keys), do: {:ok, other}

  # Every enc: string in `value` decrypted, or :error.
  defp opened("enc:" <> _ = value), do: value |> Crypto.decrypt() |> ok_or_error()

  defp opened(value) when is_map(value),
    do: value |> Enum.to_list() |> opened_list() |> ok_map(&Map.new/1)

  defp opened(value) when is_list(value), do: opened_list(value)
  defp opened(value), do: {:ok, value}

  defp opened_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      value |> opened_item() |> appended(acc)
    end)
    |> ok_map(&Enum.reverse/1)
  end

  defp opened_item({k, v}), do: v |> opened() |> ok_map(&{k, &1})
  defp opened_item(v), do: opened(v)

  defp appended({:ok, item}, acc), do: {:cont, {:ok, [item | acc]}}
  defp appended(:error, _acc), do: {:halt, :error}

  defp ok_map({:ok, value}, fun), do: {:ok, fun.(value)}
  defp ok_map(:error, _fun), do: :error

  defp ok_or_error({:ok, value}), do: {:ok, value}
  defp ok_or_error({:error, _}), do: :error

  defp kept(true, value), do: {:ok, value}
  defp kept(false, _value), do: :error

  defp opens?(value),
    do: not String.starts_with?(value, "enc:") or match?({:ok, _}, Crypto.decrypt(value))

  defp collected(results) do
    if Enum.all?(results, &match?({:ok, _}, &1)),
      do: {:ok, Enum.map(results, &elem(&1, 1))},
      else: {:error, "a sealed value does not decrypt under this SECRET_KEY_BASE"}
  end
end
