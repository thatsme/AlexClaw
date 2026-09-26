defmodule AlexClaw.Google.TokenManager do
  @moduledoc """
  Manages Google OAuth2 access tokens. Caches the current access token
  in ETS and refreshes it automatically before expiry.

  The cache is `:private`. Its rows are bearer credentials, so no process other
  than this one can read them — `:protected` would stop writes and still leave
  the tokens readable by anything running in the VM, a dynamic skill included.
  Every read is therefore a call, which is the right trade: reads are
  per-request on the Google skills, not a hot path.

  Usage:
    case AlexClaw.Google.TokenManager.get_token() do
      {:ok, token} -> # use token
      {:error, :not_configured} -> # Google OAuth not set up
      {:error, reason} -> # refresh failed
    end
  """
  use GenServer
  require Logger
  import AlexClaw.Skills.Helpers, only: [blank?: 1]

  alias AlexClaw.Config

  @table :google_token_cache
  @state_table :google_oauth_states
  @state_ttl_seconds 600
  @token_url "https://oauth2.googleapis.com/token"
  @refresh_margin_seconds 300

  # Longer than the refresh request it may have to wait behind. The default 5s
  # would have every caller give up while the owner was still talking to
  # Google, which is the one moment the call is not quick.
  @call_timeout 15_000

  # --- Client API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Get a valid access token, refreshing it first if the cached one has expired.

  Goes through the owner because the cache is `:private`: the contents are
  bearer credentials, and a table any process could read is a table a dynamic
  skill could read.
  """
  @spec get_token() :: {:ok, String.t()} | {:error, atom()}
  def get_token, do: GenServer.call(__MODULE__, :get_token, @call_timeout)

  @doc "Check if Google OAuth is configured and token is valid."
  @spec status() :: :connected | :expired | :not_configured | :error
  def status do
    cached_status(configured?())
  end

  defp cached_status(false), do: :not_configured
  defp cached_status(true), do: GenServer.call(__MODULE__, :status, @call_timeout)

  defp expiry_status([{:access_token, _token, expires_at}], now) when now < expires_at do
    :connected
  end

  defp expiry_status(_cached, _now), do: :expired

  @doc "Force a token refresh."
  @spec refresh() :: {:ok, String.t()} | {:error, any()}
  def refresh do
    GenServer.call(__MODULE__, :refresh, @call_timeout)
  end

  @doc """
  Record an OAuth CSRF state against the chat that started the flow.

  Expired states are purged on the way through, which is cheap and keeps the
  table from growing on abandoned flows.
  """
  @spec put_state(String.t(), String.t()) :: :ok
  def put_state(state, chat_id) do
    GenServer.call(__MODULE__, {:put_state, state, chat_id})
  end

  @doc """
  Consume an OAuth CSRF state, returning the chat it belongs to.

  Lookup and delete happen together inside the owner, so a state cannot be
  redeemed twice by two callbacks arriving at once. Returns `:expired` for a
  state older than the TTL, `:error` when it is unknown or already used.
  """
  @spec take_state(String.t()) :: {:ok, String.t()} | :expired | :error
  def take_state(state) do
    GenServer.call(__MODULE__, {:take_state, state})
  end

  # --- GenServer ---

  @impl true
  @spec init(keyword()) :: {:ok, map()}
  def init(_opts) do
    # :private, not :protected. The rows are bearer credentials, and :protected
    # would still let any process in the VM read them — a dynamic skill runs in
    # this VM. Reads go through this process instead; see get_token/0.
    :ets.new(@table, [:named_table, :private, :set])
    # The OAuth CSRF states live here too, owned by this process rather than by
    # whichever request happened to start a flow first.
    :ets.new(@state_table, [:named_table, :protected, :set])

    if configured?() do
      send(self(), :initial_refresh)
    end

    {:ok, %{}}
  end

  @impl true
  @spec handle_info(term(), map()) :: {:noreply, map()}
  def handle_info(:initial_refresh, state) do
    do_refresh()
    {:noreply, state}
  end

  @impl true
  def handle_info(:scheduled_refresh, state) do
    do_refresh()
    {:noreply, state}
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), map()) :: {:reply, term(), map()}
  def handle_call(:refresh, _from, state) do
    result = do_refresh()
    {:reply, result, state}
  end

  def handle_call({:put_state, oauth_state, chat_id}, _from, state) do
    now = System.monotonic_time(:second)
    :ets.insert(@state_table, {oauth_state, chat_id, now})
    purge_expired_states(now)
    {:reply, :ok, state}
  end

  def handle_call({:take_state, oauth_state}, _from, state) do
    now = System.monotonic_time(:second)
    {:reply, taken(:ets.lookup(@state_table, oauth_state), now), state}
  end

  def handle_call(:get_token, _from, state) do
    {:reply, token_or_refresh(cached_token(), System.monotonic_time(:second)), state}
  end

  def handle_call(:status, _from, state) do
    {:reply, expiry_status(cached_token(), System.monotonic_time(:second)), state}
  end

  # Test seam, compiled only under MIX_ENV=test. A :private cache cannot be
  # seeded from outside the owner, and that is the property, not an
  # inconvenience to route around — so the way in exists in the test build and
  # nowhere else. A running instance has no function that writes a bearer token
  # into the cache.
  if Mix.env() == :test do
    def handle_call({:seed_token, token, expires_at}, _from, state) do
      :ets.insert(@table, {:access_token, token, expires_at})
      {:reply, :ok, state}
    end

    def handle_call(:clear_token, _from, state) do
      :ets.delete(@table, :access_token)
      {:reply, :ok, state}
    end

    @doc false
    @spec seed_token(String.t(), integer()) :: :ok
    def seed_token(token, expires_at) do
      GenServer.call(__MODULE__, {:seed_token, token, expires_at})
    end

    @doc false
    @spec clear_token() :: :ok
    def clear_token, do: GenServer.call(__MODULE__, :clear_token)
  end

  defp purge_expired_states(now) do
    @state_table
    |> :ets.tab2list()
    |> Enum.each(fn {state, _chat_id, created_at} ->
      if now - created_at > @state_ttl_seconds, do: :ets.delete(@state_table, state)
    end)
  end

  defp taken([], _now), do: :error

  defp taken([{state, chat_id, created_at}], now) do
    :ets.delete(@state_table, state)
    fresh(chat_id, now - created_at > @state_ttl_seconds)
  end

  defp fresh(_chat_id, true), do: :expired
  defp fresh(chat_id, false), do: {:ok, chat_id}

  # --- Internal ---

  # Read from inside the owner, which is the only process that can.
  defp cached_token, do: :ets.lookup(@table, :access_token)

  defp token_or_refresh([{:access_token, token, expires_at}], now) when now < expires_at do
    {:ok, token}
  end

  defp token_or_refresh(_cached, _now), do: do_refresh()

  defp do_refresh do
    client_id = Config.get("google.oauth.client_id")
    client_secret = Config.secret_value("google.oauth.client_secret")
    refresh_token = Config.secret_value("google.oauth.refresh_token")

    if blank?(client_id) or blank?(client_secret) or blank?(refresh_token) do
      {:error, :not_configured}
    else
      body = %{
        client_id: client_id,
        client_secret: client_secret,
        refresh_token: refresh_token,
        grant_type: "refresh_token"
      }

      case Req.post(@token_url, form: body, receive_timeout: 10_000) do
        {:ok, %{status: 200, body: %{"access_token" => token, "expires_in" => expires_in}}} ->
          expires_at = System.monotonic_time(:second) + expires_in - @refresh_margin_seconds
          :ets.insert(@table, {:access_token, token, expires_at})

          refresh_in_ms = max((expires_in - @refresh_margin_seconds) * 1000, 60_000)
          Process.send_after(self(), :scheduled_refresh, refresh_in_ms)

          Logger.info("Google OAuth token refreshed (expires in #{expires_in}s)")
          {:ok, token}

        {:ok, %{status: status, body: body}} ->
          Logger.error("Google OAuth refresh failed: #{status} #{inspect(body)}")
          {:error, {:oauth_refresh_failed, status}}

        {:error, reason} ->
          Logger.error("Google OAuth request failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc "Whether Google OAuth is set up: client id, client secret and a refresh token."
  @spec configured?() :: boolean()
  def configured? do
    not blank?(Config.get("google.oauth.client_id")) and
      Config.secret_set?("google.oauth.client_secret") and
      Config.secret_set?("google.oauth.refresh_token")
  end
end
