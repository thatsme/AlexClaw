defmodule AlexClaw.Config do
  @moduledoc """
  Runtime configuration system. DB-persisted, ETS-cached.
  Supports typed values (string, integer, float, boolean, json).
  Changes are broadcast via Phoenix.PubSub so LiveViews update in real time.
  """
  require Logger
  import Ecto.Query
  alias AlexClaw.Repo
  alias AlexClaw.Config.{Setting, Crypto}

  @type config_value :: String.t() | integer() | float() | boolean() | map() | list() | nil
  @type set_opts :: [type: String.t(), description: String.t() | nil, category: String.t(), sensitive: boolean()]

  @table :alexclaw_config
  @pubsub AlexClaw.PubSub
  @topic "config:changes"

  # --- ETS lifecycle ---

  @spec init() :: :ok
  def init do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :set])
      _ -> :ok
    end
    load_all_into_ets()
  end

  defp load_all_into_ets do
    case Repo.all(Setting) do
      entries when is_list(entries) ->
        Enum.each(entries, fn s ->
          s = decrypt_setting(s)
          :ets.insert(@table, {s.key, cast_value(s)})
        end)

      _ ->
        :ok
    end
  catch
    :error, %Postgrex.Error{} = e ->
      Logger.warning("Settings table not ready: #{Exception.message(e)}")
      :ok
  end

  # --- Public API ---

  @doc "Get a config value. Returns default if not set."
  @spec get(String.t(), config_value()) :: config_value()
  def get(key, default \\ nil) do
    case :ets.lookup(@table, key) do
      [{_, value}] -> value
      [] -> default
    end
  end

  @doc "Set a config value. Persists to DB and updates ETS cache."
  @spec set(String.t(), config_value(), set_opts()) :: {:ok, Setting.t()} | {:error, Ecto.Changeset.t()}
  def set(key, value, opts \\ []) do
    type = Keyword.get(opts, :type, "string")
    description = Keyword.get(opts, :description)
    category = Keyword.get(opts, :category, "general")

    existing_record = Repo.get_by(Setting, key: key)

    sensitive =
      case Keyword.fetch(opts, :sensitive) do
        {:ok, val} -> val
        :error -> (existing_record && existing_record.sensitive) || false
      end

    encoded = encode_value(value, type)

    db_value =
      if sensitive and encoded != "" do
        Crypto.encrypt!(encoded)
      else
        encoded
      end

    attrs = %{
      key: key,
      value: db_value,
      type: type,
      description: description,
      category: category,
      sensitive: sensitive
    }

    result =
      case existing_record do
        nil -> %Setting{} |> Setting.changeset(attrs) |> Repo.insert()
        existing -> existing |> Setting.changeset(attrs) |> Repo.update()
      end

    case result do
      {:ok, setting} ->
        # ETS gets the plaintext value
        plain_setting = %{setting | value: encoded}
        :ets.insert(@table, {key, cast_value(plain_setting)})
        broadcast_change(key, cast_value(plain_setting))
        {:ok, setting}

      error ->
        error
    end
  end

  @doc "Delete a config key."
  @spec delete(String.t()) :: :ok
  def delete(key) do
    case Repo.get_by(Setting, key: key) do
      nil -> :ok
      setting -> Repo.delete(setting)
    end

    :ets.delete(@table, key)
    broadcast_change(key, nil)
    :ok
  end

  @doc "List all settings, optionally filtered by category."
  @spec list(String.t() | nil) :: [Setting.t()]
  def list(category \\ nil) do
    Setting
    |> maybe_filter_category(category)
    |> order_by(:key)
    |> Repo.all()
    |> Enum.map(&decrypt_setting/1)
  end

  @doc "Subscribe to config changes."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  # --- Value casting ---

  defp cast_value(%Setting{type: "integer", value: v}) do
    case Integer.parse(v) do
      {i, _} -> i
      :error -> 0
    end
  end
  defp cast_value(%Setting{type: "float", value: v}) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> 0.0
    end
  end
  defp cast_value(%Setting{type: "boolean", value: "true"}), do: true
  defp cast_value(%Setting{type: "boolean", value: _}), do: false
  defp cast_value(%Setting{type: "json", value: v}), do: Jason.decode!(v)
  defp cast_value(%Setting{value: v}), do: v

  defp encode_value(value, "json") when is_map(value) or is_list(value), do: Jason.encode!(value)
  defp encode_value(value, _type), do: to_string(value)

  defp decrypt_setting(%Setting{sensitive: true, value: v} = s) when is_binary(v) do
    case Crypto.decrypt(v) do
      {:ok, plaintext} -> %{s | value: plaintext}
      {:error, reason} ->
        Logger.error("Failed to decrypt setting #{s.key}: #{inspect(reason)}")
        s
    end
  end

  defp decrypt_setting(s), do: s

  defp maybe_filter_category(q, nil), do: q
  defp maybe_filter_category(q, cat), do: where(q, [s], s.category == ^cat)

  defp broadcast_change(key, value) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:config_changed, key, value})
  end
end
