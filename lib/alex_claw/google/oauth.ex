defmodule AlexClaw.Google.OAuth do
  @moduledoc """
  Handles the Google OAuth2 flow initiated via Telegram.

  Flow:
  1. User sends /connect google
  2. We generate an auth URL with a random state token linked to their chat_id
  3. User taps the link, authorizes in Google
  4. Google redirects to /auth/google/callback with code + state
  5. We exchange the code for tokens, store refresh_token in Config
  6. We notify the user via Telegram
  """
  require Logger
  import AlexClaw.Skills.Helpers, only: [blank?: 1]

  alias AlexClaw.Config

  @token_url "https://oauth2.googleapis.com/token"
  @auth_url "https://accounts.google.com/o/oauth2/v2/auth"

  @scopes [
    "https://www.googleapis.com/auth/calendar.readonly",
    "https://www.googleapis.com/auth/tasks"
  ]

  @state_table :google_oauth_states

  @spec init_state_table() :: :ets.tid() | atom()
  def init_state_table do
    if :ets.whereis(@state_table) == :undefined do
      :ets.new(@state_table, [:named_table, :public, :set])
    end
  end

  @doc "Generate an OAuth authorization URL for a Telegram user."
  @spec generate_auth_url(String.t() | integer()) :: {:ok, String.t()} | {:error, atom()}
  def generate_auth_url(chat_id) do
    client_id = Config.get("google.oauth.client_id")

    if blank?(client_id) do
      {:error, :client_id_not_configured}
    else
      init_state_table()

      state = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
      redirect_uri = get_redirect_uri()

      :ets.insert(@state_table, {state, to_string(chat_id), System.monotonic_time(:second)})
      cleanup_expired_states()

      params =
        URI.encode_query(%{
          client_id: client_id,
          redirect_uri: redirect_uri,
          response_type: "code",
          scope: Enum.join(@scopes, " "),
          access_type: "offline",
          prompt: "consent",
          state: state
        })

      {:ok, "#{@auth_url}?#{params}"}
    end
  end

  @doc "Add additional scopes for future skills (e.g. Keep, Tasks)."
  @spec add_scope(String.t()) :: :ok
  def add_scope(scope) do
    # This is for documentation — when adding new Google skills,
    # add the scope to @scopes above and ask users to re-authorize.
    Logger.info("Additional Google scope requested: #{scope}")
    :ok
  end

  @doc "Handle the OAuth callback — exchange code for tokens."
  @spec handle_callback(String.t(), String.t()) :: {:ok, String.t()} | {:error, atom()}
  def handle_callback(code, state) do
    init_state_table()

    case :ets.lookup(@state_table, state) do
      [{^state, chat_id, created_at}] ->
        :ets.delete(@state_table, state)

        if System.monotonic_time(:second) - created_at > 600 do
          {:error, :state_expired}
        else
          exchange_code(code, chat_id)
        end

      [] ->
        {:error, :invalid_state}
    end
  end

  @doc "Disconnect Google — remove stored tokens."
  @spec disconnect() :: :ok
  def disconnect do
    Config.set("google.oauth.refresh_token", "",
      type: "string",
      category: "google",
      description: "Google OAuth refresh token (obtained via one-time authorization flow)"
    )

    Logger.info("Google OAuth disconnected")
    :ok
  end

  @doc "Check if Google OAuth is connected."
  @spec connected?() :: boolean()
  def connected? do
    not blank?(Config.get("google.oauth.refresh_token"))
  end

  # --- Internal ---

  defp exchange_code(code, chat_id) do
    client_id = Config.get("google.oauth.client_id")
    client_secret = Config.get("google.oauth.client_secret")
    redirect_uri = get_redirect_uri()

    body = %{
      code: code,
      client_id: client_id,
      client_secret: client_secret,
      redirect_uri: redirect_uri,
      grant_type: "authorization_code"
    }

    case Req.post(@token_url, form: body, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: %{"refresh_token" => refresh_token}}} ->
        Config.set("google.oauth.refresh_token", refresh_token,
          type: "string",
          category: "google",
          description: "Google OAuth refresh token (obtained via one-time authorization flow)"
        )

        AlexClaw.Google.TokenManager.refresh()

        Logger.info("Google OAuth connected successfully")
        {:ok, chat_id}

      {:ok, %{status: 200, body: body}} ->
        # Token response without refresh_token (user already authorized before)
        Logger.warning("Google OAuth: no refresh_token in response — user may need to re-consent")

        if body["access_token"] do
          {:error, :no_refresh_token}
        else
          {:error, :unexpected_response}
        end

      {:ok, %{status: status, body: body}} ->
        Logger.error("Google OAuth code exchange failed: #{status} #{inspect(body)}")
        {:error, {:exchange_failed, status}}

      {:error, reason} ->
        Logger.error("Google OAuth request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp get_redirect_uri do
    case Config.get("google.oauth.redirect_uri") do
      nil -> "http://localhost:5001/auth/google/callback"
      "" -> "http://localhost:5001/auth/google/callback"
      uri -> uri
    end
  end

  defp cleanup_expired_states do
    now = System.monotonic_time(:second)

    Enum.each(:ets.tab2list(@state_table), fn {state, _chat_id, created_at} ->
      if now - created_at > 600 do
        :ets.delete(@state_table, state)
      end
    end)
  end

end
