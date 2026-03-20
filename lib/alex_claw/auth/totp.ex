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

  @issuer "AlexClaw"
  @account "admin"

  # Pending 2FA challenges: chat_id -> %{action: ..., expires_at: ...}
  @challenges_table :totp_challenges

  def init_tables do
    if :ets.whereis(@challenges_table) == :undefined do
      :ets.new(@challenges_table, [:named_table, :public, :set])
    end
  end

  # --- Setup ---

  @doc "Generate a new TOTP secret and return it with a QR code PNG."
  @spec setup() :: {:ok, %{secret: binary(), uri: String.t(), qr_png: binary()}} | {:error, atom()}
  def setup do
    secret = NimbleTOTP.secret()

    uri =
      NimbleTOTP.otpauth_uri("#{@issuer}:#{@account}", secret,
        issuer: @issuer
      )

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
    Logger.info("2FA disabled")
    :ok
  end

  # --- Verification ---

  @doc "Check if 2FA is enabled."
  @spec enabled?() :: boolean()
  def enabled? do
    Config.get("auth.totp.enabled") == true or Config.get("auth.totp.enabled") == "true"
  end

  @doc "Verify a 6-digit TOTP code."
  @spec verify(String.t()) :: boolean()
  def verify(code) do
    secret_b32 = Config.get("auth.totp.secret")

    if blank?(secret_b32) do
      false
    else
      secret = Base.decode32!(secret_b32, padding: false)
      NimbleTOTP.valid?(secret, code)
    end
  end

  # --- Challenge system ---

  @doc """
  Create a pending 2FA challenge for a sensitive action.
  Returns the challenge ID. The user must respond with a valid TOTP code.
  """
  @spec create_challenge(String.t() | integer(), map()) :: String.t()
  def create_challenge(chat_id, action) do
    init_tables()
    challenge_id = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
    expires_at = System.monotonic_time(:second) + 120

    :ets.insert(@challenges_table, {
      to_string(chat_id),
      %{
        id: challenge_id,
        action: action,
        expires_at: expires_at
      }
    })

    challenge_id
  end

  @doc "Check if there's a pending challenge for this chat and try to verify the code."
  @spec resolve_challenge(String.t() | integer(), String.t()) ::
          {:ok, map()} | {:error, atom()}
  def resolve_challenge(chat_id, code) do
    init_tables()
    chat_id_str = to_string(chat_id)

    case :ets.lookup(@challenges_table, chat_id_str) do
      [{^chat_id_str, challenge}] ->
        cond do
          System.monotonic_time(:second) > challenge.expires_at ->
            :ets.delete(@challenges_table, chat_id_str)
            {:error, :challenge_expired}

          verify(code) ->
            :ets.delete(@challenges_table, chat_id_str)
            {:ok, challenge.action}

          true ->
            {:error, :invalid_code}
        end

      [] ->
        {:error, :no_challenge}
    end
  end

  @doc "Check if a chat has a pending challenge."
  @spec pending_challenge?(String.t() | integer()) :: boolean()
  def pending_challenge?(chat_id) do
    init_tables()
    case :ets.lookup(@challenges_table, to_string(chat_id)) do
      [{_, challenge}] -> System.monotonic_time(:second) <= challenge.expires_at
      [] -> false
    end
  end

end
