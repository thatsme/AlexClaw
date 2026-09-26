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

  import Ecto.Query

  alias AlexClaw.Auth.{RecoveryCodes, SecondFactor}
  alias AlexClaw.Config
  alias AlexClaw.Config.{SecretSettings, Setting}
  alias AlexClaw.Config.SecretUpgrade.Records
  alias AlexClaw.ControlPlane
  alias AlexClaw.ControlPlane.Context
  alias AlexClaw.MCP.Key
  alias AlexClaw.{Repo, Secrets, Vault}
  alias AlexClaw.Upgrade.Legacy03

  @type result :: %{
          moved: [String.t()],
          fingerprinted: [String.t()],
          records_moved: [String.t()],
          custom_moved: [{String.t(), String.t()}],
          opened: [String.t()],
          failed: [{String.t(), term()}],
          totp: :imported | :none | {:error, term()},
          recovery_codes: non_neg_integer()
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
    report_parked(result.custom_moved)
    :ignore
  end

  @doc """
  Move every declared-secret setting, and every step, resource and LLM
  provider credential (`AlexClaw.Config.SecretUpgrade.Records`), that still
  holds a value. Returns the settings moved to OpenBao, the keys that became
  a fingerprint (the MCP key), the records moved (`"step 12"`, `"resource
  3"`, `"provider 2"`), and what did not move, with why.

  What 0.3.x encrypted under `SECRET_KEY_BASE` is read here, once, through
  `AlexClaw.Upgrade.Legacy03` (0.4.0 S7), and nothing encrypted is left:
  - AlexClaw's own sensitive rows, designed to be safe at rest (the MCP key's
    fingerprint, the admin password's hash), are decrypted in place
    (`opened:`), OpenBao or not;
  - a sensitive setting the admin added that is not a declared secret goes
    to OpenBao as a parked secret, bound to nothing it can be sent to, and the
    row is emptied (`custom_moved:`, `{key, secret name}`) — to be declared or
    deleted.

  The second factor is carried over too (0.4.0 S6): a TOTP key enrolled
  before 0.4.0 is imported into OpenBao's TOTP engine (`totp:` `:imported`,
  `:none`, or `{:error, reason}`), and recovery codes stored as their plain
  digest are re-keyed (`recovery_codes:`, how many).

  Options: `vault:` — the `AlexClaw.Vault` server to use.
  """
  @spec run(keyword()) :: {:ok, result()}
  def run(opts \\ []) do
    vault = Keyword.get(opts, :vault, Vault)
    opened = open_own_rows()

    settings =
      SecretSettings.keys()
      |> Enum.map(&{&1, pending(Repo.get_by(Setting, key: &1))})
      |> Enum.reject(fn {_key, pending} -> pending == :nothing end)

    {:ok, rekeyed} = RecoveryCodes.rekey_legacy(vault: vault)

    result =
      settings
      |> moved_all(Records.pending(), custom_rows(), vault)
      |> Map.update!(:opened, &(opened.opened ++ &1))
      |> Map.update!(:failed, &(opened.failed ++ &1))
      |> Map.put(:totp, SecondFactor.impl().carry_over(vault: vault, open: &Legacy03.decrypt/1))
      |> Map.put(:recovery_codes, rekeyed)

    {:ok, result}
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
  defp moved_all([], [], [], _vault),
    do: %{
      moved: [],
      fingerprinted: [],
      records_moved: [],
      custom_moved: [],
      opened: [],
      failed: []
    }

  defp moved_all(settings, records, custom, vault) do
    status = Vault.status(server: vault)
    settings_result = settings |> by_status(status, vault) |> tally()
    records_result = records_by_status(records, status, vault)
    custom_result = custom_by_status(custom, status, vault)

    %{
      settings_result
      | failed: settings_result.failed ++ records_result.failed ++ custom_result.failed
    }
    |> Map.put(:records_moved, records_result.moved)
    |> Map.put(:custom_moved, custom_result.moved)
    |> Map.put(:opened, [])
  end

  # --- AlexClaw's own sensitive rows (0.4.0 S7) ---

  # Rows AlexClaw writes that are designed to be safe at rest: the MCP key's
  # fingerprint (an HMAC), the admin password's hash. 0.3.x — and 0.4.0 before
  # S7, through EncryptExisting — encrypted them as sensitive; they go back to
  # their plain form, with no OpenBao needed, so the admin can log in and the
  # MCP key keeps working while OpenBao is down. The 0.3.x TOTP secret is not
  # one of them: it is imported into OpenBao (`carry_over/1`).
  defp open_own_rows do
    results =
      from(s in Setting, where: like(s.value, "enc:%"))
      |> Repo.all()
      |> Enum.filter(&own_row?/1)
      |> Enum.map(&{&1.key, opened_row(&1)})

    %{
      opened: for({key, :opened} <- results, do: key),
      failed: for({key, {:error, reason}} <- results, do: {key, reason})
    }
  end

  defp own_row?(%Setting{key: key}),
    do: key in (Config.uncached_keys() -- ["auth.totp.secret"]) or own_fingerprint?(key)

  defp own_fingerprint?(key), do: SecretSettings.recognised_only?(key)

  defp opened_row(%Setting{key: key, value: stored} = setting) do
    with {:ok, value} <- plaintext(Legacy03.decrypt(stored)),
         :ok <- own_value(own_fingerprint?(key), value),
         {:ok, _setting} <- setting |> Ecto.Changeset.change(value: value) |> Repo.update() do
      :opened
    end
  end

  # A recognised-only key's row is opened in place only when it held its
  # fingerprint; a raw key is fingerprinted by the settings move instead.
  defp own_value(true, value) do
    if String.starts_with?(value, Config.fingerprint_prefix()),
      do: :ok,
      else: {:error, :not_a_fingerprint}
  end

  defp own_value(false, _value), do: :ok

  # --- Sensitive settings the admin added (0.4.0 S7) ---

  # A sensitive row that is neither a declared secret nor one of AlexClaw's
  # own: the admin added it, and before 0.4.0 it was stored encrypted. It is
  # never dropped: its value goes to OpenBao as a parked secret — bound to
  # `inbound:carried_over`, which nothing resolves for, so it is sent nowhere
  # — and the row is emptied, to be declared or deleted.
  @parked "inbound:carried_over"

  defp custom_rows do
    own = Config.uncached_keys()

    from(s in Setting, where: s.sensitive == true and s.value != "" and not is_nil(s.value))
    |> Repo.all()
    |> Enum.reject(&(SecretSettings.secret?(&1.key) or &1.key in own))
  end

  defp custom_by_status(custom, :ok, vault) do
    results = Enum.map(custom, &{&1.key, parked(&1, vault: vault)})

    %{
      moved: for({key, {:ok, name}} <- results, do: {key, name}),
      failed: for({key, {:error, reason}} <- results, do: {key, reason})
    }
  end

  defp custom_by_status(custom, {:error, reason}, _vault),
    do: %{moved: [], failed: Enum.map(custom, &{&1.key, {:vault, reason}})}

  defp parked(%Setting{key: key, value: stored} = setting, opts) do
    name = parked_name(key)

    with {:ok, value} <- plaintext(Legacy03.decrypt(stored)),
         :ok <- catalogued(Secrets.get(name), name, key),
         :ok <- name |> Secrets.put_new_value(value, opts) |> conflict_named(name),
         :ok <- read_back(name, value, opts),
         {:ok, _setting} <- setting |> Ecto.Changeset.change(parked_row(name)) |> Repo.update() do
      {:ok, name}
    end
  end

  # Parked settings have their own namespace, one name per key: never a
  # declared secret's (`setting_…`), nor another custom key's, even when the
  # keys differ only in case or punctuation, or past the length limit.
  defp parked_name(key) do
    safe = key |> String.downcase() |> String.replace(~r/[^a-z0-9_]/, "_") |> String.slice(0, 46)
    tag = :sha256 |> :crypto.hash(key) |> Base.encode16(case: :lower) |> binary_part(0, 8)
    "parked_" <> safe <> "_" <> tag
  end

  # A name that already holds another value keeps it (S8 H5, H6): the 0.3.x
  # row stays as it was, and the conflict is reported by name.
  defp conflict_named({:error, :conflict}, name), do: {:error, {:conflict, name}}
  defp conflict_named(result, _name), do: result

  defp catalogued(nil, name, key) do
    attrs = %{
      name: name,
      kind: "other",
      binding: [@parked],
      description:
        "The setting #{key}, carried over by the 0.4.0 upgrade: declare it or delete it"
    }

    case Secrets.define(attrs) do
      {:ok, _secret} -> :ok
      {:error, _changeset} -> {:error, :not_catalogued}
    end
  end

  defp catalogued(_secret, _name, _key), do: :ok

  defp parked_row(name),
    do: %{
      value: "",
      description:
        "Moved to OpenBao as the secret #{name} by the 0.4.0 upgrade: declare it or delete it"
    }

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
    with {:ok, value} <- plaintext(Legacy03.decrypt(stored)),
         {:ok, fingerprint} <- Key.fingerprint_of(value, opts),
         :ok <- recognised(Key.fingerprint_of(value, opts), fingerprint),
         {:ok, _setting} <- Config.set(key, fingerprint) do
      :fingerprinted
    end
  end

  defp move(false, %Setting{key: key, value: stored} = setting, opts) do
    name = SecretSettings.secret_name(key)

    with {:ok, value} <- plaintext(Legacy03.decrypt(stored)),
         :ok <- key |> SecretSettings.store_new(value, opts) |> conflict_named(name),
         :ok <- read_back(name, value, opts),
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

  # A setting the admin added, parked in OpenBao: named at every start it is
  # moved, since it waits for the admin to declare it or delete it.
  defp report_parked(parked) do
    Enum.each(parked, fn {key, name} ->
      Logger.warning(
        "Setting #{key} was stored encrypted; its value is now the OpenBao secret #{name}, " <>
          "sent nowhere. Declare it as a secret setting, or delete it."
      )
    end)
  end

  @doc """
  Log what an upgrade's `result` says: what moved, what did not and why, and
  a second factor that could not be carried over (S8 M11).
  """
  @spec report(result()) :: :ok
  def report(result) do
    report_moves(result)
    report_second_factor(Map.get(result, :totp))
  end

  defp report_second_factor({:error, reason}) do
    Logger.error(
      "The second factor was NOT carried over to OpenBao (#{inspect(reason)}). " <>
        "Codes are answered as unavailable until it is; it is tried again at the next start."
    )
  end

  defp report_second_factor(_imported_or_none), do: :ok

  defp report_moves(%{moved: [], fingerprinted: [], records_moved: [], failed: []}), do: :ok

  defp report_moves(%{
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

    Enum.each(failed, fn {key, reason} -> Logger.error(not_moved(key, reason)) end)
  end

  defp not_moved(key, {:conflict, name}),
    do:
      "NOT moved to OpenBao: #{key}. The secret #{name} already holds another value, " <>
        "entered since, and it is kept. The 0.3.x value stays in its database row: " <>
        "check which one is current, then clear the other."

  defp not_moved(key, reason),
    do:
      "NOT moved to OpenBao: #{key} (#{inspect(reason)}). Its database copy is untouched; " <>
        "the move is tried again at the next start."
end
