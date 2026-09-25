defmodule AlexClawTest.Legacy do
  @moduledoc """
  Settings rows as AlexClaw 0.3.x wrote them, for testing the upgrade.

  0.3.x stored every setting in the settings table through `Config.persist/3`:
  a sensitive setting's value encrypted with `AlexClaw.Config.Crypto` (AES-256-GCM
  under a key derived from `SECRET_KEY_BASE`, stored as `"enc:" <> base64`), any
  other setting's value as plain text. The current `Config` API routes a secret
  setting to OpenBao, so these helpers write and read the row directly, below
  that routing.

  Steps and resources, as 0.3.x left them:
  - a workflow step's `config` held each key some skill declares secret
    (`secret_config_keys/0`: `api_request`'s `headers`, `telegram_notify`'s
    `bot_token`) sealed with `AlexClaw.Encrypted.seal/1`, every string in it
    stored as `"enc:" <> ciphertext`; the other keys as they were;
  - a resource's `metadata`, `auth` included, was stored as it was, with no
    encryption.
  """
  alias AlexClaw.Config.{Crypto, Setting}
  alias AlexClaw.Encrypted
  alias AlexClaw.Repo

  # The secret keys 0.3.x sealed in a step config.
  @step_secret_keys ["headers", "bot_token"]

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

  defp sealed(config),
    do: Map.new(config, fn {k, v} -> {k, seal_if(k in @step_secret_keys, v)} end)

  defp seal_if(true, value), do: Encrypted.seal(value)
  defp seal_if(false, value), do: value

  defp next_position(workflow_id) do
    %{rows: [[max]]} =
      Repo.query!("SELECT MAX(position) FROM workflow_steps WHERE workflow_id = $1", [workflow_id])

    (max || 0) + 1
  end
end
