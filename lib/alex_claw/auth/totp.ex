defmodule AlexClaw.Auth.TOTP do
  @moduledoc """
  TOTP (Time-based One-Time Password) for 2FA on sensitive actions.

  Setup flow via Telegram:
  1. /setup 2fa → generates secret, sends QR code image
  2. User scans QR with Google Authenticator
  3. User confirms with first code → 2FA enabled

  Verification flow:
  1. User triggers a sensitive action (e.g. /deploy, a workflow marked requires_2fa)
  2. AlexClaw asks for 6-digit code
  3. User sends code
  4. AlexClaw verifies and executes the action
  """
  require Logger
  import AlexClaw.Skills.Helpers, only: [blank?: 1]

  alias AlexClaw.Config
  alias AlexClaw.Config.Crypto
  alias AlexClaw.Config.Setting
  alias AlexClaw.Repo

  @account "admin"
  @last_used_key "auth.totp.last_used_at"

  defp issuer, do: System.get_env("TOTP_ISSUER", "AlexClaw")

  # A challenge is a two-minute window in which any six digits can be tried.
  # The table itself is owned by AlexClaw.Auth.ChallengeStore, so a challenge
  # outlives the process that raised it.

  # --- Setup ---

  @doc "Generate a new TOTP secret and return it with a QR code PNG."
  @spec setup() ::
          {:ok, %{secret: binary(), uri: String.t(), qr_png: binary()}} | {:error, atom()}
  def setup do
    secret = NimbleTOTP.secret()

    uri =
      NimbleTOTP.otpauth_uri("#{issuer()}:#{@account}", secret, issuer: issuer())

    qr_png =
      uri
      |> EQRCode.encode()
      |> EQRCode.png()

    Config.set("auth.totp.pending_secret", Base.encode32(secret, padding: false),
      type: "string",
      category: "auth",
      description: "Pending TOTP secret (awaiting confirmation)",
      sensitive: true
    )

    {:ok, %{secret: secret, uri: uri, qr_png: qr_png}}
  end

  @doc "Confirm 2FA setup by verifying the first code from the authenticator app."
  @spec confirm_setup(String.t()) :: :ok | {:error, atom()}
  def confirm_setup(code) do
    pending = Config.get("auth.totp.pending_secret")

    if blank?(pending) do
      {:error, :no_pending_setup}
    else
      secret = Base.decode32!(pending, padding: false)

      if NimbleTOTP.valid?(secret, code) do
        Config.set("auth.totp.secret", pending,
          type: "string",
          category: "auth",
          description: "Active TOTP secret for 2FA",
          sensitive: true
        )

        Config.set("auth.totp.enabled", "true",
          type: "boolean",
          category: "auth",
          description: "2FA enabled"
        )

        Config.delete("auth.totp.pending_secret")
        Logger.info("2FA enabled successfully")
        :ok
      else
        {:error, :invalid_code}
      end
    end
  end

  @doc "Disable 2FA."
  @spec disable() :: :ok
  def disable do
    Config.set("auth.totp.enabled", "false",
      type: "boolean",
      category: "auth",
      description: "2FA enabled"
    )

    Config.delete("auth.totp.secret")
    Config.delete("auth.totp.pending_secret")
    Config.delete(@last_used_key)
    Logger.info("2FA disabled")
    :ok
  end

  # --- Verification ---

  @doc "Check if 2FA is enabled."
  @spec enabled?() :: boolean()
  def enabled? do
    Config.enabled?("auth.totp.enabled")
  end

  @doc """
  Whether this instance has a second factor that can actually answer.

  The flag on its own is not one. A row saying `auth.totp.enabled = true` with
  no secret behind it describes an instance that reports 2FA as configured,
  refuses every code because there is nothing to compare against, and hides the
  setup button because the page asks the same question — a control plane that
  is read-only with no way out of it. That state shipped to production and was
  cleared by hand.

  `secret/0` rather than the presence of the row: a value that is there but
  cannot be decrypted is no more usable than one that is absent, and it fails
  the same way.
  """
  @spec configured?() :: boolean()
  def configured?, do: enabled?() and secret() != nil

  @doc """
  Verify a 6-digit TOTP code.

  A code stays valid for its whole 30-second period, so one observed in transit
  — read over the operator's shoulder, or lifted from a gateway an attacker can
  see — could be used again within that window. The time of the last accepted
  code is passed to `NimbleTOTP.valid?/3` as `since:`, which refuses any code
  from a period that has already been accepted.
  """
  @spec verify(String.t()) :: boolean()
  def verify(code) do
    case secret() do
      nil -> false
      secret_b32 -> verified(Base.decode32!(secret_b32, padding: false), code)
    end
  end

  defp verified(secret, code) do
    secret
    |> NimbleTOTP.valid?(code, since_opts(last_used_at()))
    |> record_if_accepted()
  end

  defp since_opts(nil), do: []
  defp since_opts(unix), do: [since: unix]

  defp record_if_accepted(false), do: false

  defp record_if_accepted(true) do
    Config.set(@last_used_key, to_string(System.os_time(:second)),
      type: "string",
      category: "auth",
      description: "Unix time of the last accepted TOTP code (replay guard)"
    )

    true
  end

  # Kept out of the config cache with the secret, so it is read from the row.
  defp last_used_at do
    case Repo.get_by(Setting, key: @last_used_key) do
      nil -> nil
      %Setting{value: value} -> parsed_unix(value)
    end
  end

  defp parsed_unix(value) when is_binary(value) do
    case Integer.parse(value) do
      {unix, ""} -> unix
      _not_an_integer -> nil
    end
  end

  defp parsed_unix(_value), do: nil

  @doc """
  Read the TOTP secret.

  The secret is deliberately not in the config cache: `Config.get/2` cannot serve
  it and `SkillAPI.config_get/3` cannot reach it. This reads the row and decrypts
  it each time, so the plaintext exists only for the length of a verification.
  """
  @spec secret() :: String.t() | nil
  def secret do
    case Repo.get_by(Setting, key: "auth.totp.secret") do
      nil -> nil
      %Setting{value: value} -> decoded_secret(value)
    end
  end

  defp decoded_secret(value) do
    case Crypto.decrypt(value) do
      {:ok, plaintext} -> presence(plaintext)
      {:error, reason} -> log_undecryptable(reason)
    end
  end

  defp presence(value) when is_binary(value), do: if(blank?(value), do: nil, else: value)
  defp presence(_value), do: nil

  defp log_undecryptable(reason) do
    Logger.error("Could not decrypt the TOTP secret: #{inspect(reason)}")
    nil
  end
end
