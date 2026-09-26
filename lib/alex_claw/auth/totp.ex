defmodule AlexClaw.Auth.TOTP do
  @moduledoc """
  The admin's second factor: an authenticator app's time-based codes.

  The key lives in OpenBao's TOTP secrets engine (`totp/keys/admin`), which
  checks the codes; AlexClaw never stores it. Enrolment (`setup/0`) has
  OpenBao create the key and shows its otpauth URI and QR code once;
  `confirm_setup/1` turns 2FA on with the first code. OpenBao refuses a code
  it has already accepted in its window, but that memory is lost when OpenBao
  restarts, so AlexClaw keeps its own guard on top: the last accepted code is
  refused for 90 seconds, as long as it could be valid.

  A key enrolled before 0.4.0 — a Base32 secret in the `auth.totp.secret`
  row — is imported into OpenBao the first time it is needed (or by the
  secret upgrade at boot) and the row is deleted: the phone keeps its entry.
  """
  require Logger

  import AlexClaw.Skills.Helpers, only: [blank?: 1]

  alias AlexClaw.Auth.RecoveryCodes
  alias AlexClaw.Config
  alias AlexClaw.Config.Setting
  alias AlexClaw.{Repo, Vault}

  @account "admin"
  # The key's name in OpenBao's TOTP engine; AlexClaw's policy covers this one.
  @key "admin"
  @last_used_key "auth.totp.last_used_at"
  @issuer_key "auth.totp.issuer"
  # Rows that say where the key is, never what it is: "admin" once enrolled in
  # OpenBao, "true" while an enrolment waits for its first code.
  @key_marker "auth.totp.key"
  @pending_marker "auth.totp.pending"
  # Before 0.4.0 the secret itself was kept here.
  @legacy_secret "auth.totp.secret"
  @replay_window 90

  # TOTP_ISSUER did not reach the app before 0.3.47, so an enrolment made then
  # carries this name whatever the variable says.
  @default_issuer "AlexClaw"

  defp issuer, do: System.get_env("TOTP_ISSUER", @default_issuer)

  @doc """
  The name of the authenticator entry, as it was enrolled.

  Recorded when 2FA is confirmed: the entry on the phone keeps the issuer it
  was enrolled with, so changing `TOTP_ISSUER` later does not rename it. An
  enrolment with no record predates the record and is named "AlexClaw".
  """
  @spec enrolled_issuer() :: String.t()
  def enrolled_issuer, do: enrolled_or_default(Config.get(@issuer_key))

  defp enrolled_or_default(issuer) when is_binary(issuer) and issuer != "", do: issuer
  defp enrolled_or_default(_none), do: @default_issuer

  # A challenge is a two-minute window in which any six digits can be tried.
  # The table itself is owned by AlexClaw.Auth.ChallengeStore, so a challenge
  # outlives the process that raised it.

  # --- Setup ---

  @doc """
  Have OpenBao create the admin's TOTP key and return what enrolment shows:
  the otpauth URI, its QR code (PNG) and the secret for typing by hand — the
  only time the secret leaves OpenBao. Nothing of it is stored here. Refused
  while 2FA is on: the active factor is replaced only by turning it off first,
  which takes a current code (`disable/1`).
  """
  @spec setup() ::
          {:ok, %{secret: binary(), uri: String.t(), qr_png: binary()}}
          | {:error, :already_enabled | :unavailable}
  def setup, do: new_setup(enabled?())

  defp new_setup(true), do: {:error, :already_enabled}

  defp new_setup(false) do
    with {:ok, %{url: uri, barcode: qr_png}} <-
           vault_result(Vault.totp_create(@key, issuer(), @account)) do
      mark(@pending_marker, "true", "A 2FA enrolment waiting for its first code")
      {:ok, %{secret: secret_of(uri), uri: uri, qr_png: qr_png}}
    end
  end

  defp secret_of(uri) do
    uri
    |> URI.parse()
    |> Map.get(:query)
    |> URI.decode_query()
    |> Map.get("secret", "")
    |> Base.decode32!(padding: false)
  end

  @doc """
  Confirm 2FA setup with the first code from the authenticator app, checked by
  OpenBao. Never replaces an active key: while 2FA is on, it is refused.
  """
  @spec confirm_setup(String.t()) :: :ok | {:error, atom()}
  def confirm_setup(code), do: confirm_when(enabled?(), code)

  defp confirm_when(true, _code), do: {:error, :already_enabled}
  defp confirm_when(false, code), do: confirm_pending(recorded(@pending_marker), code)

  defp confirm_pending(nil, _code), do: {:error, :no_pending_setup}

  defp confirm_pending(_pending, code) do
    with :ok <- validated(Vault.totp_validate(@key, normalize(code))) do
      Config.set("auth.totp.enabled", "true",
        type: "boolean",
        category: "auth",
        description: "2FA enabled"
      )

      Config.set(@issuer_key, issuer(),
        type: "string",
        category: "auth",
        description: "Authenticator entry name, as enrolled"
      )

      mark(@key_marker, @key, "The admin's TOTP key in OpenBao")
      unmark(@pending_marker)
      Logger.info("2FA enabled successfully")
      :ok
    end
  end

  @doc """
  Abandon an enrolment waiting for its first code: its key is deleted in
  OpenBao. Refused with `{:error, :already_enabled}` while 2FA is on: the key
  then is the enabled factor's, whatever pending marker is left (S8 M9).
  """
  @spec cancel_setup() :: {:ok, :cancelled} | {:error, :already_enabled}
  def cancel_setup, do: cancel_when(enabled?())

  defp cancel_when(true), do: {:error, :already_enabled}

  defp cancel_when(false) do
    cancelled(recorded(@pending_marker))
    {:ok, :cancelled}
  end

  defp cancelled(nil), do: :ok

  defp cancelled(_pending) do
    unmark(@pending_marker)
    Vault.totp_delete(@key)
  end

  @doc """
  Disable 2FA, when `code` is a current authenticator code or an unused
  recovery code (the lost-phone path). See `disable_by/1`.
  """
  @spec disable(String.t()) :: :ok | {:error, :invalid_code}
  def disable(code) do
    with {:ok, _factor} <- disable_by(code), do: disabled()
  end

  @doc """
  Disable 2FA with `code`, and say which factor did it: `:totp` for a current
  authenticator code, `:recovery_code` for an unused recovery code.

  The code is verified here — replay protection for an authenticator code, a
  recovery code spent — so no caller can turn the second factor off by
  forgetting to check it. Turning it off wipes every recovery code: with no
  second factor they unlock nothing.

  Only the database changes here, so that it can run in a transaction that may
  still roll back (the control plane's, whose audit row comes after): a
  rollback leaves 2FA on everywhere (S8 M17). Once committed, `disabled/0`
  tells the cache and deletes the key in OpenBao.
  """
  @spec disable_by(String.t()) :: {:ok, :totp | :recovery_code} | {:error, :invalid_code}
  def disable_by(code) when is_binary(code) do
    code
    |> normalize()
    |> factor()
    |> disabled_in_database()
  end

  defp factor(code), do: authenticator_or_recovery(check(code), code)

  defp authenticator_or_recovery(:ok, _code), do: {:ok, :totp}
  defp authenticator_or_recovery(_refused, code), do: recovery(RecoveryCodes.redeem(code))

  defp recovery({:ok, _remaining}), do: {:ok, :recovery_code}
  defp recovery({:error, _reason}), do: {:error, :invalid_code}

  @disable_keys [@key_marker, @pending_marker, @legacy_secret, @last_used_key]

  defp disabled_in_database({:error, :invalid_code} = refused), do: refused

  defp disabled_in_database({:ok, factor}) do
    {:ok, _setting} =
      Config.persist("auth.totp.enabled", "false",
        type: "boolean",
        category: "auth",
        description: "2FA enabled"
      )

    for key <- @disable_keys, do: {:ok, _removed} = Config.remove(key)
    RecoveryCodes.discard()
    Logger.info("2FA disabled (#{factor})")
    {:ok, factor}
  end

  @doc """
  What follows a disable once it is committed (`disable_by/1`): the cache is
  told, and the key is deleted in OpenBao. Safe to repeat.
  """
  @spec disabled() :: :ok
  def disabled do
    Enum.each(["auth.totp.enabled" | @disable_keys], &Config.publish/1)
    deleted_key(Vault.totp_delete(@key))
  end

  # The markers are gone, so nothing asks OpenBao for this key again; a key
  # left there is logged, and replaced by the next enrolment.
  defp deleted_key(:ok), do: :ok
  defp deleted_key({:error, :not_found}), do: :ok

  defp deleted_key({:error, reason}),
    do: Logger.warning("2FA disabled, but its key in OpenBao was not deleted: #{reason}")

  @doc "Check if 2FA is enabled."
  @spec enabled?() :: boolean()
  def enabled? do
    Config.enabled?("auth.totp.enabled")
  end

  @doc """
  Whether this instance has a second factor that can actually answer: 2FA on,
  and a key enrolled in OpenBao (or one from before 0.4.0 still to import).

  The flag on its own is not one. A row saying `auth.totp.enabled = true` with
  no key behind it describes an instance that reports 2FA as configured,
  refuses every code because there is nothing to compare against, and hides the
  setup button because the page asks the same question — a control plane that
  is read-only with no way out of it. That state shipped to production and was
  cleared by hand.
  """
  @spec configured?() :: boolean()
  def configured?, do: enabled?() and key_recorded?()

  @doc "Whether a key is recorded: enrolled in OpenBao, or from before 0.4.0 and still to import."
  @spec key_recorded?() :: boolean()
  def key_recorded?, do: recorded(@key_marker) != nil or recorded(@legacy_secret) != nil

  # --- Verification ---

  @doc """
  Check a 6-digit code, with OpenBao.

  Returns `:ok`, `{:error, :invalid_code}`, or `{:error, :unavailable}` when
  OpenBao cannot be asked — not a wrong code, and not counted as one
  (`AlexClaw.Auth.CodeEntry`). OpenBao refuses a code it has already
  accepted, but forgets when it restarts; AlexClaw also refuses the last
  accepted code for #{@replay_window} seconds — its longest validity, one
  period each side — so a restart does not reopen it. Options: `vault:` —
  the `AlexClaw.Vault` server to use.
  """
  @spec check(String.t(), keyword()) :: :ok | {:error, :invalid_code | :unavailable}
  # OpenBao is asked first, so an unreachable one reads as unavailable; the
  # guard then judges only a code it accepted.
  def check(code, opts \\ []) when is_binary(code) do
    code = normalize(code)
    now = System.os_time(:second)

    with :ok <- carried_over(import_legacy(opts)),
         :ok <- enrolled(recorded(@key_marker)),
         :ok <- @key |> Vault.totp_validate(code, server(opts)) |> validated(),
         :ok <- not_replayed(last_accepted(), fingerprint(code), now) do
      record_accepted(fingerprint(code), now)
    end
  end

  # The row is "<unix>:<fingerprint>". A bare unix time (a row from before
  # 0.4.0) names no code, so it refuses none.
  defp last_accepted, do: @last_used_key |> recorded() |> parsed_accepted()

  defp parsed_accepted(value) when is_binary(value) do
    with [unix | fingerprint] <- String.split(value, ":", parts: 2),
         {at, ""} <- Integer.parse(unix) do
      {at, List.first(fingerprint)}
    else
      _unreadable -> nil
    end
  end

  defp parsed_accepted(nil), do: nil

  defp not_replayed({at, fingerprint}, fingerprint, now) when now - at < @replay_window,
    do: {:error, :invalid_code}

  defp not_replayed(_last, _fingerprint, _now), do: :ok

  defp record_accepted(fingerprint, now) do
    mark(
      @last_used_key,
      "#{now}:#{fingerprint}",
      "Time and keyed fingerprint of the last accepted TOTP code (replay guard)"
    )

    :ok
  end

  # Keyed, so the row does not hold the code in a form that could be read back.
  defp fingerprint(code) do
    key =
      :alex_claw
      |> Application.fetch_env!(AlexClawWeb.Endpoint)
      |> Keyword.fetch!(:secret_key_base)

    Base.encode16(:crypto.mac(:hmac, :sha256, key, "totp-used:" <> code), case: :lower)
  end

  @doc "Whether `code` is accepted now: `check/2` as a boolean."
  @spec verify(String.t()) :: boolean()
  def verify(code), do: check(code) == :ok

  # A key from before 0.4.0 that could not be imported — OpenBao unreachable,
  # or the row still as 0.3.x encrypted it, which only the boot upgrade opens
  # — leaves nothing to compare a code against: unavailable, not a wrong code,
  # so it is not counted against the locks (S8 M11).
  defp carried_over({:error, _reason}), do: {:error, :unavailable}
  defp carried_over(_imported_or_none), do: :ok

  defp enrolled(nil), do: {:error, :invalid_code}
  defp enrolled(_key), do: :ok

  defp validated({:ok, true}), do: :ok
  defp validated({:ok, false}), do: {:error, :invalid_code}
  # Malformed, already used, or no such key: OpenBao answers 400.
  defp validated({:error, reason}) when reason in [:invalid, :not_found],
    do: {:error, :invalid_code}

  defp validated({:error, _unavailable}), do: {:error, :unavailable}

  defp vault_result({:error, reason}) when reason in [:vault_unavailable, :forbidden],
    do: {:error, :unavailable}

  defp vault_result(result), do: result

  defp normalize(code), do: String.replace(code, ~r/\s/, "")

  # --- A key from before 0.4.0 ---

  @doc """
  Import the secret an enrolment before 0.4.0 left in the `auth.totp.secret`
  row into OpenBao, then delete the row. `:imported`, `:none` when there is
  nothing to import, or `{:error, reason}` — the row is kept and the import
  tried again next time. Options: `vault:`; `open:` — a function opening the
  stored value, which the boot upgrade passes for a row 0.3.x encrypted.
  """
  @spec import_legacy(keyword()) :: :imported | :none | {:error, term()}
  def import_legacy(opts \\ []),
    do: legacy_import(recorded(@legacy_secret), Keyword.get(opts, :open, &plain/1), server(opts))

  # Without an opener, only a row holding the Base32 text is imported. A row
  # 0.3.x left encrypted is opened by the boot upgrade, which passes `open:`
  # (0.4.0 S7): nothing here decrypts.
  defp plain("enc:" <> _sealed), do: {:error, :sealed}
  defp plain(secret), do: {:ok, secret}

  # `vault:` here is AlexClaw.Vault's `server:`.
  defp server(opts), do: [server: Keyword.get(opts, :vault, Vault)]

  defp legacy_import(nil, _open, _opts), do: :none

  defp legacy_import(stored, open, opts) do
    with {:ok, secret} <- decrypted(open.(stored)),
         :ok <- Vault.totp_import(@key, secret, enrolled_issuer(), @account, opts) do
      mark(@key_marker, @key, "The admin's TOTP key in OpenBao")
      unmark(@legacy_secret)
      Logger.info("The TOTP key enrolled before 0.4.0 is now in OpenBao")
      :imported
    end
  end

  defp decrypted({:ok, secret}) when is_binary(secret), do: {:ok, secret}
  defp decrypted({:ok, nil}), do: {:error, :undecryptable}
  defp decrypted({:error, :sealed}), do: {:error, :sealed}
  defp decrypted({:error, _reason}), do: {:error, :undecryptable}

  # --- The rows ---

  # Read from the row, not the config cache: these are about the second factor,
  # and a cached copy could disagree with the database.
  defp recorded(key) do
    case Repo.get_by(Setting, key: key) do
      %Setting{value: value} when is_binary(value) -> presence(value)
      _absent -> nil
    end
  end

  defp presence(value), do: present(blank?(value), value)

  defp present(true, _value), do: nil
  defp present(false, value), do: value

  defp mark(key, value, description) do
    Config.set(key, value, type: "string", category: "auth", description: description)
  end

  defp unmark(key), do: Config.delete(key)
end
