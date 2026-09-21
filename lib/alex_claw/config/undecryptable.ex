defmodule AlexClaw.Config.Undecryptable do
  @moduledoc """
  Stored values that do not decrypt under the running `SECRET_KEY_BASE`: the
  sensitive settings, provider credentials, and the step config keys skills
  declare secret (`AlexClaw.Encrypted`).

  At boot any such value stops the start (`AlexClaw.Database.EncryptCredentials`):
  the usual cause is a changed key, and the fix is the previous key or a proper
  rotation. When the previous key is lost for good, `discard/1` clears exactly
  these values — and nothing that still decrypts — in one transaction, with an
  audit row naming the rows. Values are never logged or reported, only where
  they are.
  """

  alias AlexClaw.Auth.AuditLog
  alias AlexClaw.Encrypted
  alias AlexClaw.Repo
  alias AlexClaw.Workflows.SkillRegistry

  @type entry ::
          {:setting, integer(), String.t()}
          | {:provider, integer(), String.t()}
          | {:step, integer(), String.t()}

  @doc "Every stored value that does not decrypt, by where it is."
  @spec list() :: [entry()]
  def list, do: settings() ++ providers() ++ steps(SkillRegistry.secret_config_keys())

  @doc "Where an entry is, for a message: never its value."
  @spec describe(entry()) :: String.t()
  def describe({:setting, _id, key}), do: "settings #{key}"
  def describe({:provider, id, column}), do: "llm_providers #{id} #{column}"
  def describe({:step, id, key}), do: "workflow_steps #{id} config.#{key}"

  @doc "The confirmation `discard/1` asks for, given what would be discarded."
  @spec confirmation([entry()]) :: String.t()
  def confirmation(entries), do: "DISCARD #{length(entries)}"

  @doc """
  Clear every value that does not decrypt, if `confirmation` is what
  `confirmation/1` answers for them now. A setting becomes empty, a provider's
  API key `NULL`, and an undecryptable string in headers or a step secret
  empty; what still decrypts is kept. Audited, in one transaction.
  """
  @spec discard(String.t() | nil) :: {:ok, [entry()]} | {:error, String.t()}
  def discard(confirmation) do
    Repo.transaction(fn ->
      entries = list()
      confirmed(entries, confirmation == confirmation(entries))
    end)
  end

  defp confirmed([], _), do: Repo.rollback("Nothing to discard: every stored value decrypts")

  defp confirmed(entries, false) do
    Repo.rollback(
      "Not confirmed. This would discard #{length(entries)} values; " <>
        "confirm with \"#{confirmation(entries)}\""
    )
  end

  defp confirmed(entries, true) do
    Enum.each(entries, &clear/1)

    "operator"
    |> AuditLog.record_admin_write(
      "undecryptable values discarded (SECRET_KEY_BASE lost): " <>
        Enum.map_join(entries, ", ", &describe/1)
    )
    |> audited(entries)
  end

  defp audited(:ok, entries), do: entries

  defp audited(_error, _entries),
    do: Repo.rollback("the audit row could not be written — nothing was changed")

  # --- Finding them ---

  defp settings do
    for [id, key, value] <- rows("SELECT id, key, value FROM settings WHERE value LIKE 'enc:%'"),
        not Encrypted.decryptable?(value),
        do: {:setting, id, key}
  end

  defp providers do
    for [id, api_key, headers] <- rows("SELECT id, api_key, headers FROM llm_providers"),
        {column, value} <- [{"api_key", api_key}, {"headers", headers}],
        not Encrypted.decryptable?(value),
        do: {:provider, id, column}
  end

  defp steps(keys) do
    for [id, config] <- rows("SELECT id, config FROM workflow_steps"),
        is_map(config),
        {key, value} <- Map.take(config, keys),
        not Encrypted.decryptable?(value),
        do: {:step, id, key}
  end

  defp rows(select) do
    %{rows: rows} = Repo.query!(select <> " ORDER BY id FOR UPDATE")
    rows
  end

  # --- Clearing them ---

  defp clear({:setting, id, _key}),
    do: Repo.query!("UPDATE settings SET value = '' WHERE id = $1", [id])

  defp clear({:provider, id, "api_key"}),
    do: Repo.query!("UPDATE llm_providers SET api_key = NULL WHERE id = $1", [id])

  defp clear({:provider, id, "headers"}) do
    %{rows: [[headers]]} = Repo.query!("SELECT headers FROM llm_providers WHERE id = $1", [id])
    Repo.query!("UPDATE llm_providers SET headers = $2 WHERE id = $1", [id, kept(headers)])
  end

  defp clear({:step, id, key}) do
    %{rows: [[config]]} = Repo.query!("SELECT config FROM workflow_steps WHERE id = $1", [id])
    config = Map.update!(config, key, &kept/1)
    Repo.query!("UPDATE workflow_steps SET config = $2 WHERE id = $1", [id, config])
  end

  # Every string that does not decrypt emptied; everything else as it was.
  defp kept("enc:" <> _ = value), do: if(Encrypted.decryptable?(value), do: value, else: "")
  defp kept(value) when is_map(value), do: Map.new(value, fn {k, v} -> {k, kept(v)} end)
  defp kept(value) when is_list(value), do: Enum.map(value, &kept/1)
  defp kept(value), do: value
end
