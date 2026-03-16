defmodule AlexClaw.Google.TokenManager do
  @moduledoc """
  Manages Google OAuth2 access tokens. Caches the current access token
  in ETS and refreshes it automatically before expiry.

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
  @token_url "https://oauth2.googleapis.com/token"
  @refresh_margin_seconds 300

  # --- Client API ---

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Get a valid access token. Returns cached token or refreshes if expired."
  @spec get_token() :: {:ok, String.t()} | {:error, atom()}
  def get_token do
    case :ets.lookup(@table, :access_token) do
      [{:access_token, token, expires_at}] ->
        if System.monotonic_time(:second) < expires_at do
          {:ok, token}
        else
          GenServer.call(__MODULE__, :refresh)
        end

      [] ->
        GenServer.call(__MODULE__, :refresh)
    end
  end

  @doc "Check if Google OAuth is configured and token is valid."
  @spec status() :: :connected | :expired | :not_configured | :error
  def status do
    if configured?() do
      case :ets.lookup(@table, :access_token) do
        [{:access_token, _token, expires_at}] ->
          if System.monotonic_time(:second) < expires_at, do: :connected, else: :expired

        [] ->
          :expired
      end
    else
      :not_configured
    end
  end

  @doc "Force a token refresh."
  @spec refresh() :: {:ok, String.t()} | {:error, any()}
  def refresh do
    GenServer.call(__MODULE__, :refresh)
  end

  # --- GenServer ---

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set])

    if configured?() do
      send(self(), :initial_refresh)
    end

    {:ok, %{}}
  end

  @impl true
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
  def handle_call(:refresh, _from, state) do
    result = do_refresh()
    {:reply, result, state}
  end

  # --- Internal ---

  defp do_refresh do
    client_id = Config.get("google.oauth.client_id")
    client_secret = Config.get("google.oauth.client_secret")
    refresh_token = Config.get("google.oauth.refresh_token")

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

  defp configured? do
    not blank?(Config.get("google.oauth.client_id")) and
      not blank?(Config.get("google.oauth.client_secret")) and
      not blank?(Config.get("google.oauth.refresh_token"))
  end

end
