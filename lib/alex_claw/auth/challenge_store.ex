defmodule AlexClaw.Auth.ChallengeStore do
  @moduledoc """
  Supervised owner of the pending 2FA challenge table.

  The table used to be created lazily by whichever process first raised a
  challenge, which could be a LiveView. Closing that tab took the table with it
  and every pending challenge in it. It is now created here, in `init/1`, so it
  lives as long as the supervision tree.

  The table is `:protected`: this process writes, everything else reads. A write
  from anywhere else raises rather than silently succeeding, which is what makes
  the ownership claim enforceable instead of conventional.

  Attempt counting is a read-modify-write, so it happens inside the owner as one
  call. Two wrong codes arriving together cannot lose an increment between them.
  """
  use GenServer

  @table :totp_challenges

  @typedoc "A chat id, or a session raising its own challenge in the admin UI."
  @type key :: String.t() | {:web, String.t()}

  # --- Client ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Store a challenge, replacing any already pending for that key.

  A key is a chat id for a challenge sent to a gateway, or `{:web, sid}` for
  one raised by a session typing its code into the admin UI. Both hold the same
  shape, expire the same way, and are executed by the same function — the key
  only says where the code is expected from.
  """
  @spec put(key(), map()) :: :ok
  def put(chat_id, challenge) do
    GenServer.call(__MODULE__, {:put, chat_id, challenge})
  end

  @doc "Forget a challenge. Used on success, expiry and cancellation."
  @spec drop(key()) :: :ok
  def drop(chat_id) do
    GenServer.call(__MODULE__, {:drop, chat_id})
  end

  @doc """
  Count one failed attempt against a challenge.

  Returns `{:error, :too_many_attempts}` and forgets the challenge once `max`
  is reached, `{:error, :invalid_code}` while attempts remain.
  """
  @spec record_attempt(key(), pos_integer()) ::
          {:error, :invalid_code | :too_many_attempts | :no_challenge}
  def record_attempt(chat_id, max) do
    GenServer.call(__MODULE__, {:record_attempt, chat_id, max})
  end

  @doc "Read a pending challenge. Reads go straight to the table."
  @spec fetch(key()) :: {:ok, map()} | :error
  def fetch(key) do
    case :ets.lookup(@table, key) do
      [{^key, challenge}] -> {:ok, challenge}
      [] -> :error
    end
  end

  # --- Server ---

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :protected, :set])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:put, chat_id, challenge}, _from, state) do
    :ets.insert(@table, {chat_id, challenge})
    {:reply, :ok, state}
  end

  def handle_call({:drop, chat_id}, _from, state) do
    :ets.delete(@table, chat_id)
    {:reply, :ok, state}
  end

  def handle_call({:record_attempt, chat_id, max}, _from, state) do
    {:reply, count_attempt(:ets.lookup(@table, chat_id), max), state}
  end

  # A process that is not the owner cannot write, so this runs here or nowhere.
  defp count_attempt([], _max), do: {:error, :no_challenge}

  defp count_attempt([{chat_id, %{attempts: attempts}}], max) when attempts + 1 >= max do
    :ets.delete(@table, chat_id)
    {:error, :too_many_attempts}
  end

  defp count_attempt([{chat_id, challenge}], _max) do
    :ets.insert(@table, {chat_id, %{challenge | attempts: challenge.attempts + 1}})
    {:error, :invalid_code}
  end
end
