defmodule AlexClawTest.Legacy do
  @moduledoc """
  Rows as AlexClaw 0.3.x wrote them, for testing the upgrade.

  0.3.x stored every setting in the settings table through `Config.persist/3`:
  a sensitive setting's value encrypted (AES-256-GCM under a key derived from
  `SECRET_KEY_BASE` by HKDF-SHA256, stored as `"enc:" <> base64(iv <> ciphertext
  <> tag)`), any other setting's value as plain text. The current `Config` API
  routes a secret setting to OpenBao, so these helpers write and read the row
  directly, below that routing.

  Steps, resources and LLM providers, as 0.3.x left them:
  - a workflow step's `config` held each key some skill declares secret
    (`secret_config_keys/0`: `api_request`'s `headers`, `telegram_notify`'s
    `bot_token`) sealed, every string in it stored as `"enc:" <> ciphertext`;
    the other keys as they were;
  - a resource's `metadata`, `auth` included, was stored as it was, with no
    encryption;
  - a provider's `api_key` column held its key sealed, and its `headers`
    column every header value sealed.

  Since 0.4.0 (S7) the application holds no code that encrypts, so the seal
  is written out here, as 0.3.x's `AlexClaw.Config.Crypto` did it.
  """
  alias AlexClaw.Config.Setting
  alias AlexClaw.Repo

  # The secret keys 0.3.x sealed in a step config.
  @step_secret_keys ["headers", "bot_token"]

  @doc "`value` sealed as 0.3.x sealed it: every non-empty string in it encrypted."
  @spec seal(term()) :: term()
  def seal(value) when value in [nil, ""], do: value
  def seal(value) when is_binary(value), do: encrypt(value)
  def seal(value) when is_map(value), do: Map.new(value, fn {k, v} -> {k, seal(v)} end)
  def seal(value) when is_list(value), do: Enum.map(value, &seal/1)
  def seal(value), do: value

  @doc "A 0.3.x ciphertext opened again (for assertions about what was sealed)."
  @spec open(String.t()) :: String.t()
  def open("enc:" <> encoded) do
    raw = Base.decode64!(encoded)
    size = byte_size(raw) - 28
    <<iv::binary-12, ciphertext::binary-size(size), tag::binary-16>> = raw
    :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, ciphertext, <<>>, tag, false)
  end

  def open(plaintext), do: plaintext

  defp encrypt(plaintext) do
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, plaintext, <<>>, 16, true)

    "enc:" <> Base.encode64(iv <> ciphertext <> tag)
  end

  defp key do
    secret_key_base =
      :alex_claw
      |> Application.fetch_env!(AlexClawWeb.Endpoint)
      |> Keyword.fetch!(:secret_key_base)

    prk = :crypto.mac(:hmac, :sha256, <<0::256>>, secret_key_base)
    binary_part(:crypto.mac(:hmac, :sha256, prk, <<"AlexClaw.Config.Crypto", 1>>), 0, 32)
  end

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
        open(value)
    end
  end

  defp stored(value, true), do: encrypt(value)
  defp stored(value, false), do: value

  @doc """
  Insert a step of `skill` with `config` into workflow `workflow_id`, after its
  last step, as 0.3.x stored it. Returns the step's id.
  """
  @spec insert_step(integer(), String.t(), map()) :: integer()
  def insert_step(workflow_id, skill, config) do
    now = DateTime.utc_now(:second)

    {1, [%{id: id}]} =
      Repo.insert_all(
        "workflow_steps",
        [
          %{
            workflow_id: workflow_id,
            position: next_position(workflow_id),
            name: "Legacy #{skill}",
            skill: skill,
            config: sealed(config),
            inserted_at: now,
            updated_at: now
          }
        ],
        returning: [:id]
      )

    id
  end

  @doc "Insert an `api` resource at `url` with `metadata`, as 0.3.x stored it. Returns its id."
  @spec insert_resource(String.t(), map()) :: integer()
  def insert_resource(url, metadata) do
    now = DateTime.utc_now(:second)

    {1, [%{id: id}]} =
      Repo.insert_all(
        "resources",
        [
          %{
            name: "Legacy #{System.unique_integer([:positive])}",
            type: "api",
            url: url,
            metadata: metadata,
            tags: [],
            enabled: true,
            inserted_at: now,
            updated_at: now
          }
        ],
        returning: [:id]
      )

    id
  end

  @doc """
  Insert an LLM provider with `api_key` and `headers` as 0.3.x stored them
  (both sealed), into the legacy columns. Returns its id.
  """
  @spec insert_provider(map()) :: integer()
  def insert_provider(attrs) do
    now = DateTime.utc_now(:second)

    row =
      %{
        name: "legacy-#{System.unique_integer([:positive])}",
        type: "openai_compatible",
        tier: "light",
        host: nil,
        model: "m",
        enabled: false,
        priority: 100,
        options: %{},
        inserted_at: now,
        updated_at: now
      }
      |> Map.merge(Map.drop(attrs, [:api_key, :headers]))
      |> Map.put(:api_key, seal(Map.get(attrs, :api_key)))
      |> Map.put(:headers, seal(Map.get(attrs, :headers, %{})))

    {1, [%{id: id}]} = Repo.insert_all("llm_providers", [row], returning: [:id])
    id
  end

  defp sealed(config),
    do: Map.new(config, fn {k, v} -> {k, seal_if(k in @step_secret_keys, v)} end)

  defp seal_if(true, value), do: seal(value)
  defp seal_if(false, value), do: value

  defp next_position(workflow_id) do
    %{rows: [[max]]} =
      Repo.query!("SELECT MAX(position) FROM workflow_steps WHERE workflow_id = $1", [workflow_id])

    (max || 0) + 1
  end
end
