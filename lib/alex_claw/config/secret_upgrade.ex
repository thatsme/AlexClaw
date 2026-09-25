defmodule AlexClaw.Config.SecretUpgrade do
  @moduledoc """
  At boot, before the gateways start: moves every declared-secret setting that
  still holds a value in the settings table into OpenBao, so no credential
  configured before 0.4.0 is lost or has to be entered again.

  For each such setting, in this order:

  1. the value is read from the settings table, decrypted under the running
     `SECRET_KEY_BASE`;
  2. it is stored in OpenBao through `AlexClaw.Config.SecretSettings.store/2`
     (catalogued, bound as declared, audited);
  3. it is READ BACK from OpenBao and compared with what was read in step 1;
  4. only then is the value emptied in the settings table.

  The MCP key is recognised, never stored (`AlexClaw.MCP.Key`), so it is not
  moved: its fingerprint is computed from it (twice, and compared, before the
  row is touched) and stored in its place. A configured MCP client keeps
  working with the key it has.

  Any failure — OpenBao unreachable, a write refused, a value that does not
  decrypt, a read-back that differs — leaves the database copy exactly as it
  was, is logged by the setting's name (never its value), and the move is tried
  again at the next start. A setting already moved, or never set, is left
  alone, so running this at every boot changes nothing once everything is in
  OpenBao.
  """
  require Logger

  alias AlexClaw.Config
  alias AlexClaw.Config.{Crypto, SecretSettings, Setting}
  alias AlexClaw.Config.SecretUpgrade.Records
  alias AlexClaw.ControlPlane
  alias AlexClaw.ControlPlane.Context
  alias AlexClaw.MCP.Key
  alias AlexClaw.{Repo, Secrets, Vault}

  @type result :: %{
          moved: [String.t()],
          fingerprinted: [String.t()],
          records_moved: [String.t()],
          failed: [{String.t(), term()}]
        }

  @doc false
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_arg),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, []}, restart: :temporary}

  @doc false
  @spec start_link() :: :ignore
  def start_link do
    {:ok, result} =
      ControlPlane.perform(:upgrade_secrets, %{}, Context.system("secret upgrade at boot"))

    report(result)
    :ignore
  end

  @doc """
  Move every declared-secret setting, and every step and resource credential
  (`AlexClaw.Config.SecretUpgrade.Records`), that still holds a value.
  Returns the settings moved to OpenBao, the keys that became a fingerprint
  (the MCP key), the records moved (`"step 12"`, `"resource 3"`), and what did
  not move, with why.

  Options: `vault:` — the `AlexClaw.Vault` server to use.
  """
  @spec run(keyword()) :: {:ok, result()}
  def run(opts \\ []) do
    settings =
      SecretSettings.keys()
      |> Enum.map(&{&1, pending(Repo.get_by(Setting, key: &1))})
      |> Enum.reject(fn {_key, pending} -> pending == :nothing end)

    {:ok, moved_all(settings, Records.pending(), Keyword.get(opts, :vault, Vault))}
  end

  defp pending(nil), do: :nothing
  defp pending(%Setting{value: value}) when value in [nil, ""], do: :nothing

  defp pending(%Setting{value: value} = setting),
    do:
      pending_unless_fingerprint(String.starts_with?(value, Config.fingerprint_prefix()), setting)

  defp pending_unless_fingerprint(true, _setting), do: :nothing
  defp pending_unless_fingerprint(false, setting), do: {:move, setting}

  # Nothing to move: OpenBao is not even asked, so an instance without it boots
  # as before once everything has moved.
  defp moved_all([], [], _vault),
    do: %{moved: [], fingerprinted: [], records_moved: [], failed: []}

  defp moved_all(settings, records, vault) do
    status = Vault.status(server: vault)
    settings_result = settings |> by_status(status, vault) |> tally()
    records_result = records_by_status(records, status, vault)

    %{
      settings_result
      | failed: settings_result.failed ++ records_result.failed
    }
    |> Map.put(:records_moved, records_result.moved)
  end

  defp records_by_status(records, :ok, vault), do: Records.move_all(records, vault: vault)

  defp records_by_status(records, {:error, reason}, _vault),
    do: %{moved: [], failed: Enum.map(records, &{Records.label(&1), {:vault, reason}})}

  defp by_status(pending, :ok, vault),
    do: Enum.map(pending, fn {key, {:move, s}} -> {key, move(s, vault)} end)

  defp by_status(pending, {:error, reason}, _vault),
    do: Enum.map(pending, fn {key, _move} -> {key, {:error, {:vault, reason}}} end)

  defp move(%Setting{key: key} = setting, vault),
    do: move(SecretSettings.recognised_only?(key), setting, vault: vault)

  # A recognised-only key: its fingerprint replaces it. Computed twice and
  # compared before the row is touched, as a moved value is read back: the key
  # is dropped only for a fingerprint that recognises it.
  defp move(true, %Setting{key: key, value: stored}, opts) do
    with {:ok, value} <- plaintext(Crypto.decrypt(stored)),
         {:ok, fingerprint} <- Key.fingerprint_of(value, opts),
         :ok <- recognised(Key.fingerprint_of(value, opts), fingerprint),
         {:ok, _setting} <- Config.set(key, fingerprint) do
      :fingerprinted
    end
  end

  defp move(false, %Setting{key: key, value: stored} = setting, opts) do
    with {:ok, value} <- plaintext(Crypto.decrypt(stored)),
         :ok <- SecretSettings.store(key, value, opts),
         :ok <- read_back(SecretSettings.secret_name(key), value, opts),
         {:ok, _setting} <- setting |> Ecto.Changeset.change(value: "") |> Repo.update() do
      :ok
    end
  end

  defp recognised({:ok, fingerprint}, fingerprint), do: :ok
  defp recognised({:ok, _other}, _fingerprint), do: {:error, :fingerprint_differs}
  defp recognised({:error, reason}, _fingerprint), do: {:error, {:fingerprint, reason}}

  defp plaintext({:ok, value}) when is_binary(value) and value != "", do: {:ok, value}
  defp plaintext({:ok, _empty}), do: {:error, :empty}
  defp plaintext({:error, _reason}), do: {:error, :does_not_decrypt}

  defp read_back(name, value, opts) do
    case Secrets.value_matches?(name, value, opts) do
      true -> :ok
      false -> {:error, :read_back_differs}
      {:error, reason} -> {:error, {:read_back, reason}}
    end
  end

  defp tally(results) do
    %{
      moved: for({key, :ok} <- results, do: key),
      fingerprinted: for({key, :fingerprinted} <- results, do: key),
      failed: for({key, {:error, reason}} <- results, do: {key, reason})
    }
  end

  defp report(%{moved: [], fingerprinted: [], records_moved: [], failed: []}), do: :ok

  defp report(%{
         moved: moved,
         fingerprinted: fingerprinted,
         records_moved: records,
         failed: failed
       }) do
    if records != [],
      do:
        Logger.info(
          "Credentials moved to OpenBao: #{Enum.join(records, ", ")} (the rows keep references)"
        )

    if moved != [],
      do:
        Logger.info(
          "Moved to OpenBao: #{Enum.join(moved, ", ")} (the settings table keeps no value)"
        )

    if fingerprinted != [],
      do:
        Logger.info(
          "Kept as a fingerprint: #{Enum.join(fingerprinted, ", ")} (the key itself is dropped)"
        )

    Enum.each(failed, fn {key, reason} ->
      Logger.error(
        "NOT moved to OpenBao: #{key} (#{inspect(reason)}). Its database copy is untouched; " <>
          "the move is tried again at the next start."
      )
    end)
  end
end
