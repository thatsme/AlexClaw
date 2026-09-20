defmodule AlexClaw.Config do
  @moduledoc """
  Runtime configuration system. DB-persisted, ETS-cached.
  Supports typed values (string, integer, float, boolean, json).
  Changes are broadcast via Phoenix.PubSub so LiveViews update in real time.
  """
  require Logger
  import Ecto.Query
  alias AlexClaw.Config.{Crypto, Setting}
  alias AlexClaw.Repo

  @type config_value :: String.t() | integer() | float() | boolean() | map() | list() | nil
  @type set_opts :: [
          type: String.t(),
          description: String.t() | nil,
          category: String.t(),
          sensitive: boolean()
        ]

  @table :alexclaw_config
  @pubsub AlexClaw.PubSub
  @topic "config:changes"

  # The second factor is not configuration. It is never cached and never served
  # through get/2, so the only way to it is AlexClaw.Auth.TOTP's own accessor.
  #
  # get/2 raises for these rather than answering nil. Answering nil made the
  # guard indistinguishable from absence, and the seeder — which asked get/2
  # whether a key was already set — concluded the secret was missing and wrote
  # its empty default over it. Every restart erased the enrolment, and the
  # instance was then left claiming a second factor it no longer had.
  #
  # A caller that reaches for one of these has made a mistake that nil would
  # hide, so it is raised and not returned.
  @uncached_keys ["auth.totp.secret", "auth.totp.last_used_at"]

  @doc "Keys that get/2 refuses and the seeder must never write a default over."
  @spec uncached_keys() :: [String.t()]
  def uncached_keys, do: @uncached_keys

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
        entries
        |> Enum.reject(&(&1.key in @uncached_keys))
        |> Enum.each(fn s ->
          decrypted = decrypt_setting(s)
          :ets.insert(@table, {s.key, cast_value(decrypted), s.sensitive})
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

  @doc """
  Get a config value. Returns default if not set.

  Raises for a key the cache deliberately does not hold — see `@uncached_keys`.
  Those have an owner with its own accessor, and answering nil here would say
  "not set" about a value that is very much set.
  """
  @spec get(String.t(), config_value()) :: config_value()
  def get(key, default \\ nil)

  def get(key, _default) when key in @uncached_keys do
    raise ArgumentError, """
    #{key} is not served through Config.get/2.

    It is deliberately kept out of the config cache, so this would answer nil
    whether the value is absent or merely hidden — and a caller that cannot
    tell those apart will eventually overwrite one with the other.

    Use the accessor belonging to whatever owns the key. The owner is the module
    that writes it.
    """
  end

  def get(key, default) do
    case :ets.lookup(@table, key) do
      [{_key, value, _sensitive}] -> value
      # Tolerated rather than matched-or-crash: a config read should degrade, not
      # take the caller down, if anything ever writes the older two-tuple shape.
      [{_key, value}] -> value
      [] -> default
    end
  end

  @doc """
  Whether a setting is marked sensitive.

  Callers that hand values to untrusted code — `SkillAPI.config_get/3` — use this
  to refuse rather than serve. Unknown keys are treated as sensitive: a key that
  is not in the cache cannot be shown to be safe.
  """
  @spec sensitive?(String.t()) :: boolean()
  def sensitive?(key) when key in @uncached_keys, do: true

  def sensitive?(key) do
    case :ets.lookup(@table, key) do
      [{_key, _value, sensitive}] -> sensitive
      _unknown_shape_or_missing -> true
    end
  end

  @doc """
  Whether a boolean setting is on.

  Settings are persisted as strings, so `get/2` returns `"true"` rather than
  `true` for a setting the seeder types as boolean. Comparing the result against
  `true` is therefore always false — a mistake that silently disabled the backup
  skill and the reverse-proxy header setting. Use this instead of reading the
  value and comparing it.
  """
  @spec enabled?(String.t()) :: boolean()
  def enabled?(key), do: get(key) in [true, "true"]

  @doc "Set a config value. Persists to DB and updates ETS cache."
  @spec set(String.t(), config_value(), set_opts()) ::
          {:ok, Setting.t()} | {:error, Ecto.Changeset.t()}
  def set(key, value, opts \\ []) do
    type = Keyword.get(opts, :type, "string")
    existing_record = Repo.get_by(Setting, key: key)
    sensitive = sensitive_flag(Keyword.fetch(opts, :sensitive), existing_record)
    encoded = encode_value(value, type)

    attrs = %{
      key: key,
      value: db_value(encoded, sensitive),
      type: type,
      description: Keyword.get(opts, :description),
      category: Keyword.get(opts, :category, "general"),
      sensitive: sensitive
    }

    existing_record
    |> upsert_setting(attrs)
    |> cache_setting(key, encoded)
  end

  defp sensitive_flag({:ok, val}, _existing_record), do: val

  defp sensitive_flag(:error, existing_record),
    do: (existing_record && existing_record.sensitive) || false

  defp db_value("", _sensitive), do: ""
  defp db_value(encoded, true), do: Crypto.encrypt!(encoded)
  defp db_value(encoded, _sensitive), do: encoded

  defp upsert_setting(nil, attrs), do: %Setting{} |> Setting.changeset(attrs) |> Repo.insert()
  defp upsert_setting(existing, attrs), do: existing |> Setting.changeset(attrs) |> Repo.update()

  defp cache_setting({:ok, %Setting{key: key} = setting}, key, _encoded)
       when key in @uncached_keys do
    {:ok, setting}
  end

  defp cache_setting({:ok, setting}, key, encoded) do
    # ETS gets the plaintext value, alongside the flag that decides who may see it
    cast = cast_value(%{setting | value: encoded})
    :ets.insert(@table, {key, cast, setting.sensitive})
    broadcast_change(key, cast)
    {:ok, setting}
  end

  defp cache_setting(error, _key, _encoded), do: error

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
      {:ok, plaintext} ->
        %{s | value: plaintext}

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
