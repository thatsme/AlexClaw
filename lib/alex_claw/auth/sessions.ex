defmodule AlexClaw.Auth.Sessions do
  @moduledoc """
  Which admin logins are live, decided on the server.

  A login is identified by the `elevation_sid` placed in the Plug session at
  login. The `admin_sessions` table is the only answer to "is that login still
  good", and every node reads the same one. A login is valid while all of
  these hold:

    * it was opened here and has not been closed;
    * it is younger than eight hours, busy or idle;
    * the admin password is still the one it was opened with. Each row carries
      a keyed fingerprint of that password, so changing the password ends
      every login at once.

  The session a request or a LiveView carries is never the answer on its own.
  A LiveView mounts from a copy of the session signed into the page, which
  LiveView accepts for two weeks and which logout cannot reach — so a copy
  saying "signed in" proves only that it once was. Every authenticated HTTP
  request and every LiveView mount asks here instead, with the sid the copy
  holds.

  The sid itself is never stored. Rows hold its SHA-256; reading the table
  signs nobody in.

  This process only sweeps: every ten minutes it deletes the rows that have
  expired, so the table holds live logins and not a history of them.
  """
  use GenServer

  import Ecto.Query

  alias AlexClaw.Auth.{AdminPassword, AdminSession}
  alias AlexClaw.{ControlPlane, Repo}

  @max_age_seconds 8 * 60 * 60
  @sweep_interval :timer.minutes(10)

  # --- Client ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc """
  Open a login for `sid`, as of `opened_at` (now, unless given), under the
  current admin password.

  The moment is a parameter so that an old login can be made without waiting
  eight hours for one.
  """
  @spec open(String.t(), integer()) :: :ok
  def open(sid, opened_at \\ now()) when is_binary(sid) do
    {:ok, _row} =
      %AdminSession{}
      |> AdminSession.changeset(%{
        token_hash: hash(sid),
        password_fingerprint: password_fingerprint(),
        inserted_at: DateTime.from_unix!(opened_at)
      })
      |> Repo.insert()

    :ok
  end

  @doc "End `sid`'s login now. A sid holding none is not an error."
  @spec close(String.t() | nil) :: :ok
  def close(nil), do: :ok

  def close(sid) when is_binary(sid) do
    Repo.delete_all(from(s in AdminSession, where: s.token_hash == ^hash(sid)))
    :ok
  end

  @doc """
  Whether `sid` is a live login. The two-argument form judges against a given
  moment, which is what makes the expiry boundary testable.
  """
  @spec valid?(String.t() | nil) :: boolean()
  def valid?(sid), do: valid?(sid, now())

  @spec valid?(String.t() | nil, integer()) :: boolean()
  def valid?(sid, now) when is_binary(sid) and sid != "" do
    cutoff = DateTime.from_unix!(now - @max_age_seconds)
    fingerprint = password_fingerprint()

    Repo.exists?(
      from(s in AdminSession,
        where:
          s.token_hash == ^hash(sid) and s.inserted_at > ^cutoff and
            s.password_fingerprint == ^fingerprint
      )
    )
  end

  def valid?(_sid, _now), do: false

  @doc """
  End every login except `keep` — the session that is still trusted — and
  close their open pages. `nil` keeps none: the event came from somewhere with
  no web session at all, such as a gateway command.

  Recorded as an outcome of `reason` in the same transaction as the delete.
  """
  @spec close_others(String.t() | nil, String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def close_others(keep, reason) do
    with {:ok, socket_ids} <-
           ControlPlane.outcome(keep, "other admin sessions signed out: #{reason}", fn ->
             remove(others(keep))
           end) do
      disconnect(socket_ids)
      {:ok, length(socket_ids)}
    end
  end

  @doc """
  Delete every login and answer the socket ids of their pages. The database
  only: for use inside `ControlPlane.gated/4`, with `disconnect/1` after commit.
  """
  @spec remove_all() :: {:ok, [String.t()]}
  def remove_all, do: remove(AdminSession)

  @doc "Close the open pages of the given logins."
  @spec disconnect([String.t()]) :: :ok
  def disconnect(socket_ids) do
    Enum.each(socket_ids, fn id ->
      Phoenix.PubSub.broadcast(AlexClaw.PubSub, id, %Phoenix.Socket.Broadcast{
        topic: id,
        event: "disconnect",
        payload: %{}
      })
    end)
  end

  @doc "Delete the logins that expired by `now`. Answers how many."
  @spec sweep(integer()) :: non_neg_integer()
  def sweep(now \\ now()) do
    cutoff = DateTime.from_unix!(now - @max_age_seconds)
    {count, _} = Repo.delete_all(from(s in AdminSession, where: s.inserted_at <= ^cutoff))
    count
  end

  @doc "How long a login lasts, in seconds."
  @spec max_age_seconds() :: pos_integer()
  def max_age_seconds, do: @max_age_seconds

  @doc """
  The LiveView socket id for `sid`'s login. Broadcasting `"disconnect"` on it
  closes every page that login has open. Named by fingerprint: a topic is not
  a place for the credential itself.
  """
  @spec socket_id(String.t()) :: String.t()
  def socket_id(sid), do: sid |> hash() |> socket_id_for()

  # --- Server ---

  @impl true
  def init(_opts) do
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule_sweep()
    {:noreply, state}
  end

  # --- Internals ---

  defp others(nil), do: AdminSession
  defp others(keep), do: from(s in AdminSession, where: s.token_hash != ^hash(keep))

  defp remove(query) do
    {_count, hashes} = Repo.delete_all(select(query, [s], s.token_hash))
    {:ok, Enum.map(hashes, &socket_id_for/1)}
  end

  # Same fingerprint as AlexClaw.Auth.Elevation.fingerprint/1: the first 16 hex
  # characters of the sid's SHA-256 — which is what the row already holds.
  defp socket_id_for(token_hash) do
    "admin_session:" <> (token_hash |> Base.encode16(case: :lower) |> binary_part(0, 16))
  end

  defp hash(sid), do: :crypto.hash(:sha256, sid)

  # Keyed, so the column is not an offline-crackable copy of the password (or
  # of its hash). It follows AdminPassword.current/0: a new password — a new
  # stored hash — ends every login made under the old one.
  defp password_fingerprint do
    :crypto.mac(:hmac, :sha256, secret_key_base(), "admin-password:" <> AdminPassword.current())
  end

  defp secret_key_base do
    :alex_claw |> Application.fetch_env!(AlexClawWeb.Endpoint) |> Keyword.fetch!(:secret_key_base)
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval)

  defp now, do: System.system_time(:second)
end
