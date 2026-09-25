defmodule AlexClaw.Config do
  @moduledoc """
  Runtime configuration system. DB-persisted, ETS-cached.
  Supports typed values (string, integer, float, boolean, json).
  Changes are broadcast via Phoenix.PubSub so LiveViews update in real time.
  """
  require Logger
  import Ecto.Query
  alias AlexClaw.Config.{SecretSettings, Setting}
  alias AlexClaw.{Repo, Secrets}

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
  @uncached_keys ["auth.totp.secret", "auth.totp.last_used_at", "auth.admin_password_hash"]

  # A recognised-only key's row holds a fingerprint, never a value.
  @fingerprint_prefix "hmac:"

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
        |> Enum.reject(&(&1.key in @uncached_keys or SecretSettings.secret?(&1.key)))
        |> Enum.each(fn s -> :ets.insert(@table, {s.key, cast_value(s), s.sensitive}) end)

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

  def get(key, default), do: from_cache(SecretSettings.secret?(key), key, default)

  # A declared-secret setting lives in OpenBao; its value is never in the cache.
  defp from_cache(true, key, _default) do
    raise ArgumentError, """
    #{key} is a secret setting: its value is kept in OpenBao, not in the config
    cache, and Config.get/2 does not serve it.

    Resolve it for the destination it is used for:
    Config.secret(#{inspect(key)}, for: Config.secret_binding(#{inspect(key)})).
    """
  end

  defp from_cache(false, key, default) do
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

  def sensitive?(key), do: SecretSettings.secret?(key) or cached_sensitive?(key)

  defp cached_sensitive?(key) do
    case :ets.lookup(@table, key) do
      [{_key, _value, sensitive}] -> sensitive
      _unknown_shape_or_missing -> true
    end
  end

  # --- Secret settings ---

  @doc "Whether `key` is a declared-secret setting (`AlexClaw.Config.SecretSettings`)."
  @spec secret?(String.t()) :: boolean()
  defdelegate secret?(key), to: SecretSettings

  @doc "The destination of a single-binding secret key, as a binding (`host:...`)."
  @spec secret_binding(String.t()) :: String.t()
  def secret_binding(key), do: SecretSettings.binding_for(key)

  @doc "Every destination the secret key `key` may be used for, as bindings."
  @spec secret_bindings(String.t()) :: [String.t()]
  def secret_bindings(key), do: SecretSettings.bindings_for(key)

  @doc """
  The value of the secret setting `key`, for the destination `for:` — through
  `AlexClaw.Secrets.resolve/2`: the binding is checked and the use audited.

  A recognised-only key (`mcp.api_key`) has no value to return:
  `{:error, :not_retrievable}`.
  """
  @spec secret(String.t(), keyword()) ::
          {:ok, String.t()} | {:error, Secrets.error() | :not_retrievable}
  def secret(key, opts), do: resolved(SecretSettings.recognised_only?(key), key, opts)

  defp resolved(true, _key, _opts), do: {:error, :not_retrievable}
  # The bindings are derived from the declaration now, never taken from the
  # first save: moving a configurable base moves the host the secret may go to.
  defp resolved(false, key, opts) do
    Secrets.resolve(
      SecretSettings.secret_name(key),
      Keyword.put(opts, :bindings, SecretSettings.bindings_for(key))
    )
  end

  @doc """
  The value of the secret setting `key` for the destination `for:`, or nil when
  it was never set or cannot be resolved. A key that was never set is not
  resolved at all, so asking writes no audit row.
  """
  @spec secret_value(String.t(), keyword()) :: String.t() | nil
  def secret_value(key, opts), do: value_if_set(secret_set?(key), key, opts)

  @doc "`secret_value/2` for a single-binding key, for its one destination."
  @spec secret_value(String.t()) :: String.t() | nil
  def secret_value(key), do: secret_value(key, for: secret_binding(key))

  defp value_if_set(false, _key, _opts), do: nil

  defp value_if_set(true, key, opts) do
    case secret(key, opts) do
      {:ok, value} -> value
      {:error, _reason} -> nil
    end
  end

  @doc "Whether the secret setting `key` has a value (or, recognised-only, a fingerprint)."
  @spec secret_set?(String.t()) :: boolean()
  def secret_set?(key), do: secret_set_at(key) != nil

  @doc """
  The stored fingerprint of the recognised-only key `key` (`mcp.api_key`), or
  nil when none is set. A fingerprint is not a secret; see `AlexClaw.MCP.Key`.
  """
  @spec fingerprint(String.t()) :: String.t() | nil
  def fingerprint(key) do
    true = SecretSettings.recognised_only?(key)
    stored_fingerprint(Repo.get_by(Setting, key: key))
  end

  defp stored_fingerprint(%Setting{value: @fingerprint_prefix <> _ = fingerprint}),
    do: fingerprint

  defp stored_fingerprint(_row), do: nil

  @doc "The prefix every stored fingerprint carries."
  @spec fingerprint_prefix() :: String.t()
  def fingerprint_prefix, do: @fingerprint_prefix

  @doc """
  Clear the setting `key`. An empty value means "keep" for a secret setting, so
  removing one is this: its value is deleted from OpenBao, with every version,
  and it no longer has a date. Any other setting is set to "".
  """
  @spec clear(String.t()) :: :ok | {:error, term()}
  def clear(key) do
    with :ok <- erase(key), do: publish(key)
  end

  @doc """
  `clear/1` without the publish: safe inside a transaction; follow it with
  `publish/1` once committed (as `persist/3` is to `set/3`).
  """
  @spec erase(String.t()) :: :ok | {:error, term()}
  def erase(key), do: erased(SecretSettings.secret?(key), key)

  defp erased(true, key), do: erased_secret(SecretSettings.recognised_only?(key), key)

  defp erased(false, key) do
    with {:ok, _setting} <- persist(key, ""), do: :ok
  end

  # A recognised-only key is cleared by dropping its fingerprint.
  defp erased_secret(true, key) do
    with {:ok, _setting} <- replace_row(Repo.get_by(Setting, key: key), ""), do: :ok
  end

  defp erased_secret(false, key) do
    case Secrets.delete(SecretSettings.secret_name(key)) do
      :ok -> :ok
      {:error, :unknown_secret} -> :ok
      error -> error
    end
  end

  defp replace_row(nil, _value), do: {:ok, nil}

  defp replace_row(setting, value),
    do: setting |> Setting.changeset(%{value: value}) |> Repo.update()

  @doc "When the secret setting `key` was last set, or nil if it never was."
  @spec secret_set_at(String.t()) :: DateTime.t() | nil
  def secret_set_at(key), do: set_at(SecretSettings.recognised_only?(key), key)

  defp set_at(true, key) do
    case Repo.get_by(Setting, key: key) do
      %Setting{value: @fingerprint_prefix <> _, updated_at: at} -> at
      _ -> nil
    end
  end

  defp set_at(false, key) do
    case Secrets.get(SecretSettings.secret_name(key)) do
      nil -> nil
      secret -> secret.rotated_at
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

  @doc """
  Set a config value: `persist/3`, then `publish/1`.

  For callers outside the control plane. A control-plane change persists inside
  `AlexClaw.ControlPlane.gated/4` and publishes after it commits.
  """
  @spec set(String.t(), config_value(), set_opts()) ::
          {:ok, Setting.t()} | {:error, Ecto.Changeset.t() | Secrets.error() | :not_settable}
  def set(key, value, opts \\ []) do
    with {:ok, setting} <- persist(key, value, opts) do
      :ok = publish(key)
      {:ok, setting}
    end
  end

  @doc """
  Write a config value to the database, and nothing else.

  Safe inside a transaction: no cache is touched and nobody is told, so a
  rollback leaves nothing to undo. Follow it with `publish/1` once committed.

  Every write goes through here, so this is where a declared-secret setting is
  routed: its value goes to OpenBao (`AlexClaw.Secrets`, catalogued and bound
  as declared) and the setting row keeps no value. "" keeps the current value;
  a new one rotates it. (An OpenBao write is not undone by a rollback.)

  A recognised-only key (`mcp.api_key`) takes only a fingerprint made by
  `AlexClaw.MCP.Key`; any other value is refused with `{:error, :not_settable}`.

  A key named like a credential (`credential_key?/1`) that is not a declared
  secret setting is refused with `{:error, :undeclared_credential}`: it would
  be stored in the table as typed (0.4.0 S7).
  """
  @spec persist(String.t(), config_value(), set_opts()) ::
          {:ok, Setting.t()}
          | {:error,
             Ecto.Changeset.t() | Secrets.error() | :not_settable | :undeclared_credential}
  def persist(key, value, opts \\ []) do
    with :ok <- declared_if_credential(key),
         do: persisted(SecretSettings.secret?(key), key, value, opts)
  end

  @credential_patterns ~w(api_key token password secret)

  @doc """
  Whether `key` is named like a credential: `api_key`, `token`, `password`
  or `secret` in it.
  """
  @spec credential_key?(String.t()) :: boolean()
  def credential_key?(key) when is_binary(key) do
    key_down = String.downcase(key)
    Enum.any?(@credential_patterns, &String.contains?(key_down, &1))
  end

  # A credential belongs in OpenBao, and only a declared secret setting is
  # routed there (0.4.0 S7): any other key named like one is refused. The keys
  # AlexClaw manages itself and never serves (@uncached_keys) are its own.
  defp declared_if_credential(key),
    do:
      credential_refusal(
        credential_key?(key) and not SecretSettings.secret?(key) and key not in @uncached_keys
      )

  defp credential_refusal(true), do: {:error, :undeclared_credential}
  defp credential_refusal(false), do: :ok

  defp persisted(true, key, value, opts),
    do: persisted_secret(SecretSettings.recognised_only?(key), key, value, opts)

  defp persisted(false, key, value, opts) do
    type = Keyword.get(opts, :type, "string")
    existing_record = Repo.get_by(Setting, key: key)
    sensitive = sensitive_flag(Keyword.fetch(opts, :sensitive), existing_record)

    attrs = %{
      key: key,
      value: encode_value(value, type),
      type: type,
      description: Keyword.get(opts, :description),
      category: Keyword.get(opts, :category, "general"),
      sensitive: sensitive
    }

    upsert_setting(existing_record, attrs)
  end

  # A recognised-only key stores its fingerprint, and nothing else: a value
  # that is not one is refused, so no key can land in the table as typed.
  defp persisted_secret(true, key, @fingerprint_prefix <> _ = fingerprint, opts) do
    upsert_setting(Repo.get_by(Setting, key: key), %{
      key: key,
      value: fingerprint,
      type: "string",
      description: Keyword.get(opts, :description),
      category: Keyword.get(opts, :category, "mcp"),
      sensitive: true
    })
  end

  defp persisted_secret(true, _key, _value, _opts), do: {:error, :not_settable}

  # OpenBao first, then the row: a failed store leaves the row as it was. A
  # value not yet moved by AlexClaw.Config.SecretUpgrade stays in the row when
  # "" (keep) is saved, so the upgrade can still move it; a new value makes it
  # obsolete.
  defp persisted_secret(false, key, value, opts) do
    type = Keyword.get(opts, :type, "string")
    encoded = encode_value(value, type)
    existing = Repo.get_by(Setting, key: key)

    attrs = %{
      key: key,
      value: row_value(encoded, existing),
      type: type,
      description: Keyword.get(opts, :description),
      category: Keyword.get(opts, :category, "general"),
      sensitive: true
    }

    with :ok <- store_secret(key, encoded), do: upsert_setting(existing, attrs)
  end

  defp row_value("", %Setting{value: not_yet_moved}), do: not_yet_moved
  defp row_value(_encoded, _existing), do: ""

  @doc """
  Make the cache and subscribers agree with what the database holds for `key`.

  Reads the committed row rather than trusting what the caller meant to write,
  so it is correct after a rollback, harmless when repeated, and repairs a cache
  that has drifted. A key the cache deliberately does not hold is announced as
  changed, never with its value.
  """
  @spec publish(String.t()) :: :ok
  def publish(key) when key in @uncached_keys do
    :ets.delete(@table, key)
    broadcast_change(key, nil)
  end

  def publish(key), do: published(SecretSettings.secret?(key), key)

  # A secret setting is announced as changed, never with its value.
  defp published(true, key) do
    :ets.delete(@table, key)
    broadcast_change(key, nil)
  end

  defp published(false, key), do: cached(Repo.get_by(Setting, key: key), key)

  # "" keeps the current value.
  defp store_secret(_key, ""), do: :ok
  defp store_secret(key, value), do: SecretSettings.store(key, value)

  defp sensitive_flag({:ok, val}, _existing_record), do: val

  defp sensitive_flag(:error, existing_record),
    do: (existing_record && existing_record.sensitive) || false

  defp upsert_setting(nil, attrs), do: %Setting{} |> Setting.changeset(attrs) |> Repo.insert()
  defp upsert_setting(existing, attrs), do: existing |> Setting.changeset(attrs) |> Repo.update()

  defp cached(nil, key) do
    :ets.delete(@table, key)
    broadcast_change(key, nil)
  end

  # ETS gets the value, alongside the flag that decides who may see it
  defp cached(%Setting{} = setting, key) do
    value = cast_value(setting)
    :ets.insert(@table, {key, value, setting.sensitive})
    broadcast_change(key, value)
  end

  @doc "Delete a config key: `remove/1`, then `publish/1`."
  @spec delete(String.t()) :: :ok
  def delete(key) do
    {:ok, _removed} = remove(key)
    publish(key)
  end

  @doc """
  Delete a config key from the database, and nothing else. Safe inside a
  transaction; follow it with `publish/1` once committed.
  """
  @spec remove(String.t()) :: {:ok, :removed | :absent} | {:error, Ecto.Changeset.t()}
  def remove(key) do
    with :ok <- forget_secret(SecretSettings.secret?(key), key),
         do: removed(Repo.get_by(Setting, key: key))
  end

  # A secret setting's row points at its secret: removing the row removes the
  # secret too — its value in OpenBao and its catalogue entry. A
  # recognised-only key holds only a fingerprint, in the row itself.
  defp forget_secret(true, key), do: forget(SecretSettings.recognised_only?(key), key)
  defp forget_secret(false, _key), do: :ok

  defp forget(true, _key), do: :ok
  defp forget(false, key), do: erased_secret(false, key)

  defp removed(nil), do: {:ok, :absent}

  defp removed(setting) do
    with {:ok, _setting} <- Repo.delete(setting), do: {:ok, :removed}
  end

  @doc "List all settings, optionally filtered by category."
  @spec list(String.t() | nil) :: [Setting.t()]
  def list(category \\ nil) do
    Setting
    |> maybe_filter_category(category)
    |> order_by(:key)
    |> Repo.all()
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

  defp maybe_filter_category(q, nil), do: q
  defp maybe_filter_category(q, cat), do: where(q, [s], s.category == ^cat)

  defp broadcast_change(key, value) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:config_changed, key, value})
  end
end
