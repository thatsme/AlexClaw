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

  alias AlexClaw.Auth.ChallengeStore
  alias AlexClaw.Auth.CodeEntry
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
  @max_attempts 3

  # How long a pending action waits for its code, either way it was raised.
  @challenge_seconds 120

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

  # --- Challenge system ---

  @doc """
  Create a pending 2FA challenge for a sensitive action.
  Returns the challenge ID. The user must respond with a valid TOTP code.
  """
  @spec create_challenge(String.t() | integer(), map()) :: String.t()
  def create_challenge(chat_id, action) do
    challenge_id = Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)

    ChallengeStore.put(to_string(chat_id), %{
      id: challenge_id,
      action: action,
      expires_at: System.monotonic_time(:second) + @challenge_seconds,
      attempts: 0
    })

    challenge_id
  end

  @doc "Check if there's a pending challenge for this chat and try to verify the code."
  @spec resolve_challenge(String.t() | integer(), String.t()) ::
          {:ok, map()} | {:error, atom()}
  def resolve_challenge(chat_id, code) do
    chat_id_str = to_string(chat_id)

    case ChallengeStore.fetch(chat_id_str) do
      {:ok, challenge} ->
        decide_challenge(challenge, chat_id_str, code)

      :error ->
        {:error, :no_challenge}
    end
  end

  # The code is checked by CodeEntry, whichever way it arrived: same replay
  # guard, same brute-force counters, same audit row. What stays here is what is
  # specific to a gateway challenge — its two-minute life, and the per-challenge
  # attempt count that discards the pending action.
  defp decide_challenge(challenge, chat_id_str, code) do
    expired(System.monotonic_time(:second) > challenge.expires_at, challenge, chat_id_str, code)
  end

  defp expired(true, _challenge, chat_id_str, _code) do
    ChallengeStore.drop(chat_id_str)
    {:error, :challenge_expired}
  end

  defp expired(false, challenge, chat_id_str, code) do
    chat_id_str
    |> session_key()
    |> CodeEntry.verify(code, :gateway)
    |> resolved(challenge, chat_id_str)
  end

  defp resolved(:ok, challenge, chat_id_str) do
    ChallengeStore.drop(chat_id_str)
    {:ok, challenge.action}
  end

  # A locked instance is not "wrong code": the caller is told to stop, and the
  # pending action is left alone rather than burned by an attempt that never
  # reached the verifier.
  defp resolved({:error, locked}, _challenge, _chat_id_str)
       when locked in [:locked_session, :locked_instance] do
    {:error, locked}
  end

  defp resolved({:error, _reason}, _challenge, chat_id_str) do
    ChallengeStore.record_attempt(chat_id_str, @max_attempts)
  end

  # A chat is the session on that side: three wrong codes from one chat lock
  # that chat, not every gateway at once.
  defp session_key(chat_id_str), do: "chat:" <> chat_id_str

  @doc "Check if a chat has a pending challenge."
  @spec pending_challenge?(String.t() | integer()) :: boolean()
  def pending_challenge?(chat_id) do
    case ChallengeStore.fetch(to_string(chat_id)) do
      {:ok, challenge} -> System.monotonic_time(:second) <= challenge.expires_at
      :error -> false
    end
  end

  @doc """
  Hold an action raised in the admin UI until its code arrives.

  The same shape as a gateway challenge, keyed by session rather than by chat,
  because the action has to outlive the click either way. Two minutes, as for a
  gateway: an approval left open on a screen is an approval someone else can
  finish.
  """
  @spec create_web_challenge(String.t(), map()) :: String.t()
  def create_web_challenge(sid, action) do
    challenge_id = Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)

    ChallengeStore.put({:web, sid}, %{
      id: challenge_id,
      action: action,
      expires_at: System.monotonic_time(:second) + @challenge_seconds,
      attempts: 0
    })

    challenge_id
  end

  @doc "The action a session is waiting to confirm, if it has not expired."
  @spec pending_web_action(String.t() | nil) :: {:ok, map()} | :error
  def pending_web_action(nil), do: :error

  def pending_web_action(sid) do
    unexpired(ChallengeStore.fetch({:web, sid}), sid)
  end

  @doc """
  Take a session's pending action, leaving nothing behind.

  Taking rather than reading: the caller is about to perform the action, and a
  second caller must not find it still waiting. The code itself is checked by
  `AlexClaw.Auth.CodeEntry`, which owns the attempt limits.
  """
  @spec take_web_action(String.t() | nil) :: {:ok, map()} | :error
  def take_web_action(sid) do
    taken = pending_web_action(sid)
    drop_web_challenge(sid)
    taken
  end

  @doc "Forget a session's pending action — cancelled, or already performed."
  @spec drop_web_challenge(String.t() | nil) :: :ok
  def drop_web_challenge(nil), do: :ok
  def drop_web_challenge(sid), do: ChallengeStore.drop({:web, sid})

  @doc "Forget a gateway's pending challenge — answered elsewhere, or cancelled."
  @spec drop_challenge(String.t() | integer()) :: :ok
  def drop_challenge(chat_id), do: ChallengeStore.drop(to_string(chat_id))

  defp unexpired({:ok, challenge}, sid) do
    fresh(System.monotonic_time(:second) <= challenge.expires_at, challenge, sid)
  end

  defp unexpired(:error, _sid), do: :error

  defp fresh(true, challenge, _sid), do: {:ok, challenge.action}

  defp fresh(false, _challenge, sid) do
    drop_web_challenge(sid)
    :error
  end
end
