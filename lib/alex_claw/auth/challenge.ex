defmodule AlexClaw.Auth.Challenge do
  @moduledoc """
  An action waiting for a second factor.

  A challenge is the action, a deadline and an attempt count. None of that
  depends on what the second factor is — an authenticator code, a recovery
  code, a hardware key one day — so it lives here rather than inside the
  implementation that happens to answer it today.

  Challenges are keyed by where the answer is expected from: a chat id for one
  sent to a gateway, `{:web, sid}` for one raised by a session in the admin UI.
  Both hold the same shape and expire the same way; the key only says where the
  code is expected from.

  Verifying the code itself belongs to `AlexClaw.Auth.CodeEntry`, which owns
  the brute-force limits and the audit trail for every route.
  """

  alias AlexClaw.Auth.{ChallengeStore, CodeAttempts, CodeEntry}

  # Long enough to fetch a phone, short enough that an approval left open on a
  # screen is not an approval someone else can finish.
  @challenge_seconds 120
  @max_attempts 3

  @doc "Raise a challenge for a gateway, and return its id."
  @spec create(String.t() | integer(), map()) :: String.t()
  def create(chat_id, action) do
    put(to_string(chat_id), action)
  end

  @doc """
  Raise a challenge for one admin session.

  Keyed by session rather than by chat, because the action has to outlive the
  click either way.
  """
  @spec create_for_session(String.t(), map()) :: String.t()
  def create_for_session(sid, action) do
    put({:web, sid}, action)
  end

  @doc """
  Answer a gateway's challenge with `code`.

  Returns the action to perform. A lock is reported as itself and leaves the
  challenge alone: an attempt that never reached the verifier must not burn one
  of the three, or an attacker could destroy a pending approval from a
  distance simply by locking the instance.
  """
  @type resolve_error ::
          :no_challenge
          | :challenge_expired
          | :locked_session
          | :locked_instance
          | :invalid_code
          | :too_many_attempts

  @spec resolve(String.t() | integer(), String.t()) :: {:ok, map()} | {:error, resolve_error()}
  def resolve(chat_id, code) do
    chat_id_str = to_string(chat_id)

    chat_id_str
    |> ChallengeStore.fetch()
    |> decide(chat_id_str, code)
  end

  @doc """
  Whether a gateway's chat may send a code now, or for how many more minutes
  it is locked (rounded up).

  The lock belongs to the chat, not to a challenge: it outlives the challenge
  that tripped it.
  """
  @spec lock(String.t() | integer()) :: :ok | {:locked, pos_integer()}
  def lock(chat_id) do
    chat_id
    |> to_string()
    |> session_key()
    |> CodeAttempts.status()
    |> minutes_left()
  end

  @doc "Whether a gateway has a challenge still waiting."
  @spec pending?(String.t() | integer()) :: boolean()
  def pending?(chat_id) do
    chat_id
    |> to_string()
    |> ChallengeStore.fetch()
    |> alive?()
  end

  @doc "The action a session is waiting to confirm, if it has not expired."
  @spec pending_for_session(String.t() | nil) :: {:ok, map()} | :error
  def pending_for_session(nil), do: :error

  def pending_for_session(sid) do
    unexpired(ChallengeStore.fetch({:web, sid}), sid)
  end

  @doc """
  Take a session's pending action, leaving nothing behind.

  Taking rather than reading: the caller is about to perform the action, and a
  second caller must not find it still waiting.
  """
  @spec take_for_session(String.t() | nil) :: {:ok, map()} | :error
  def take_for_session(sid) do
    taken = pending_for_session(sid)
    drop_for_session(sid)
    taken
  end

  @doc "Forget a session's pending action — cancelled, or already performed."
  @spec drop_for_session(String.t() | nil) :: :ok
  def drop_for_session(nil), do: :ok
  def drop_for_session(sid), do: ChallengeStore.drop({:web, sid})

  @doc "Forget a gateway's challenge — answered elsewhere, or cancelled."
  @spec drop(String.t() | integer()) :: :ok
  def drop(chat_id), do: ChallengeStore.drop(to_string(chat_id))

  @doc "How long a challenge waits for its answer."
  @spec lifetime_seconds() :: pos_integer()
  def lifetime_seconds, do: @challenge_seconds

  # --- Internals ---

  defp put(key, action) do
    id = Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)

    ChallengeStore.put(key, %{
      id: id,
      action: action,
      expires_at: System.monotonic_time(:second) + @challenge_seconds,
      attempts: 0
    })

    id
  end

  defp decide(:error, _chat_id_str, _code), do: {:error, :no_challenge}

  defp decide({:ok, challenge}, chat_id_str, code) do
    expired(past?(challenge), challenge, chat_id_str, code)
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

  defp minutes_left(:ok), do: :ok

  defp minutes_left({:locked, _kind, until}),
    do: {:locked, max(1, ceil((until - System.system_time(:second)) / 60))}

  defp alive?({:ok, challenge}), do: not past?(challenge)
  defp alive?(:error), do: false

  defp past?(challenge), do: System.monotonic_time(:second) > challenge.expires_at

  defp unexpired({:ok, challenge}, sid), do: fresh(not past?(challenge), challenge, sid)
  defp unexpired(:error, _sid), do: :error

  defp fresh(true, challenge, _sid), do: {:ok, challenge.action}

  defp fresh(false, _challenge, sid) do
    drop_for_session(sid)
    :error
  end
end
