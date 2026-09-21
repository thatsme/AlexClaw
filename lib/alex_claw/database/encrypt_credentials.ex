defmodule AlexClaw.Database.EncryptCredentials do
  @moduledoc """
  At boot, before anything reads them: encrypts the credentials stored outside
  the settings that are still in plain text, and checks that every encrypted
  one decrypts under the running `SECRET_KEY_BASE`.

  Covered: `llm_providers.api_key`, `llm_providers.headers`, and the keys of
  a step's `config` that skills declare secret (`AlexClaw.Encrypted`). Rows
  written before encryption at rest existed are in plain text until this runs
  once; after that it only checks.

  It also drops the copies of setting keys that providers were seeded with:
  a provider whose key equals its setting (`llm.gemini_api_key`,
  `llm.anthropic_api_key`) is left without one, and the LLM client reads the
  setting, as it already does for a provider without a key.

  A value that cannot be encrypted or decrypted stops the boot, naming the
  row and column and never the value. Both tables are small and read whole,
  under a row lock, in one transaction: two nodes booting together encrypt
  each row once.
  """

  require Logger

  alias AlexClaw.Encrypted
  alias AlexClaw.LLM.Client
  alias AlexClaw.Repo
  alias AlexClaw.Workflows.SkillRegistry

  @doc false
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_arg),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, []}, restart: :temporary}

  @doc false
  @spec start_link() :: :ignore
  def start_link do
    {:ok, %{encrypted: encrypted, copies: copies}} = run()

    if encrypted + copies > 0,
      do:
        Logger.info(
          "Credentials at rest: #{encrypted} encrypted, #{copies} setting copies dropped"
        )

    :ignore
  end

  @doc "Encrypt what is still plain text and check the rest. Raises on a value that fails."
  @spec run() :: {:ok, %{encrypted: non_neg_integer(), copies: non_neg_integer()}}
  def run do
    Repo.transaction(fn ->
      providers =
        Enum.map(rows("SELECT id, type, api_key, headers FROM llm_providers"), &provider/1)

      steps = Enum.map(rows("SELECT id, config FROM workflow_steps"), &step(&1, secret_keys()))

      %{
        encrypted: Enum.count(providers ++ steps, &(&1 == :encrypted)),
        copies: Enum.count(providers, &(&1 == :copy_dropped))
      }
    end)
  end

  defp rows(select) do
    %{rows: rows} = Repo.query!(select <> " ORDER BY id FOR UPDATE")
    rows
  end

  defp secret_keys, do: SkillRegistry.secret_config_keys()

  # --- llm_providers ---

  defp provider([id, type, api_key, headers]) do
    checked!(api_key, "llm_providers", id, "api_key")
    checked!(headers, "llm_providers", id, "headers")
    provider_outcome(copy?(type, api_key), id, api_key, headers)
  end

  defp provider_outcome(true, id, _api_key, headers) do
    update!("UPDATE llm_providers SET api_key = NULL, headers = $2 WHERE id = $1", [
      id,
      Encrypted.seal_plaintext(headers)
    ])

    :copy_dropped
  end

  defp provider_outcome(false, id, api_key, headers) do
    changed(
      Encrypted.plaintext?(api_key) or Encrypted.plaintext?(headers),
      "UPDATE llm_providers SET api_key = $2, headers = $3 WHERE id = $1",
      [id, Encrypted.seal_plaintext(api_key), Encrypted.seal_plaintext(headers)]
    )
  end

  # A provider seeded with a copy of its setting: the setting is the one source.
  defp copy?(type, api_key) do
    setting = Client.setting_api_key(type)
    setting not in [nil, ""] and Encrypted.open!(api_key) == setting
  end

  # --- workflow_steps ---

  defp step([_id, nil], _keys), do: :unchanged

  defp step([id, config], keys) do
    secrets = Map.take(config, keys)

    Enum.each(secrets, fn {key, value} ->
      checked!(value, "workflow_steps", id, "config.#{key}")
    end)

    changed(
      Encrypted.plaintext?(secrets),
      "UPDATE workflow_steps SET config = $2 WHERE id = $1",
      [id, Map.merge(config, Encrypted.seal_plaintext(secrets))]
    )
  end

  # --- both ---

  defp changed(true, sql, params) do
    update!(sql, params)
    :encrypted
  end

  defp changed(false, _sql, _params), do: :unchanged

  defp update!(sql, params), do: Repo.query!(sql, params)

  defp checked!(value, table, id, column) do
    unless Encrypted.decryptable?(value) do
      raise "#{table} #{id}: #{column} does not decrypt under this SECRET_KEY_BASE. " <>
              "It was encrypted under another key; see docs/deployment/rotate-secret-key-base.md."
    end
  end
end
