defmodule AlexClaw.Database.EncryptCredentials do
  @moduledoc """
  At boot, before anything reads them: checks that every encrypted value —
  sensitive settings and stored credentials — decrypts under the running
  `SECRET_KEY_BASE`, and encrypts the credentials stored outside the settings
  that are still in plain text.

  Covered: `llm_providers.api_key`, `llm_providers.headers`, and the
  credential fields of a step's `config` (`AlexClaw.Workflows.StepSecrets`)
  still holding a value in plain text. Rows written before encryption at rest
  existed are in plain text until this runs once; after that it only checks.
  Since 0.4.0 a step keeps references to OpenBao secrets instead, and
  `AlexClaw.Config.SecretUpgrade` moves what this sealed.

  It also drops the copies of setting keys that providers were seeded with:
  a provider whose key equals its setting (`llm.gemini_api_key`,
  `llm.anthropic_api_key`) is left without one, and the LLM client reads the
  setting, as it already does for a provider without a key.

  A value that does not decrypt stops the boot. The message names every such
  row and column, never a value, and says what to do: restore the previous
  key, or rotate properly; a key lost for good has its own procedure
  (`AlexClaw.Config.Undecryptable`). Both tables are small and read whole,
  under a row lock, in one transaction: two nodes booting together encrypt
  each row once.
  """

  require Logger

  alias AlexClaw.Config.Undecryptable
  alias AlexClaw.Encrypted
  alias AlexClaw.LLM.Client
  alias AlexClaw.Repo
  alias AlexClaw.Secrets.Owned
  alias AlexClaw.Workflows.StepSecrets

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
      stop_if_undecryptable!(Undecryptable.list())

      providers =
        Enum.map(rows("SELECT id, type, api_key, headers FROM llm_providers"), &provider/1)

      steps = Enum.map(rows("SELECT id, skill, config FROM workflow_steps"), &step/1)

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

  # --- llm_providers ---

  defp provider([id, type, api_key, headers]) do
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

  # A credential still in plain text in a step's config (a row older than
  # encryption at rest) is sealed until SecretUpgrade moves it to OpenBao.
  # References, and headers that carry no credential, are not credentials.
  defp step([_id, _skill, nil]), do: :unchanged

  defp step([id, skill, config]) do
    plain =
      for {path, value} <- StepSecrets.fields(skill, config),
          not Owned.reference?(value) and Encrypted.plaintext?(value),
          do: path

    changed(
      plain != [],
      "UPDATE workflow_steps SET config = $2 WHERE id = $1",
      [id, Enum.reduce(plain, config, &Owned.put(&2, &1, Encrypted.seal(Owned.get(&2, &1))))]
    )
  end

  # --- both ---

  defp changed(true, sql, params) do
    update!(sql, params)
    :encrypted
  end

  defp changed(false, _sql, _params), do: :unchanged

  defp update!(sql, params), do: Repo.query!(sql, params)

  defp stop_if_undecryptable!([]), do: :ok

  defp stop_if_undecryptable!(entries) do
    raise "These stored values do not decrypt under this SECRET_KEY_BASE: " <>
            Enum.map_join(entries, ", ", &Undecryptable.describe/1) <>
            ". Restore the previous SECRET_KEY_BASE, or change it only with the re-key " <>
            "procedure (docs/deployment/rotate-secret-key-base.md). If the previous key " <>
            "is lost for good, see \"Lost key\" in that guide."
  end
end
