defmodule AlexClaw.Google.OAuth do
  @moduledoc """
  Handles the Google OAuth2 flow, started from the admin UI (Services page).

  Flow (both steps performed as `:connect_google` through
  `AlexClaw.ControlPlane.perform/3`, with the elevation):
  1. The operator asks to connect Google.
  2. An auth URL is generated with a random state issued to that signed-in
     session (by its fingerprint).
  3. The operator authorizes in Google.
  4. Google redirects to /auth/google/callback with code + state; the
     callback needs the same signed-in session, and the state must have been
     issued to it.
  5. The code is exchanged for tokens; the refresh token goes to OpenBao.
  """
  require Logger
  import AlexClaw.Skills.Helpers, only: [blank?: 1]

  alias AlexClaw.Config
  alias AlexClaw.Google.TokenManager

  @token_url "https://oauth2.googleapis.com/token"
  @auth_url "https://accounts.google.com/o/oauth2/v2/auth"

  @scopes [
    "https://www.googleapis.com/auth/calendar.readonly",
    "https://www.googleapis.com/auth/tasks"
  ]

  @doc "Generate an OAuth authorization URL, its state issued to `owner` (a session fingerprint)."
  @spec generate_auth_url(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def generate_auth_url(owner) do
    client_id = Config.get("google.oauth.client_id")

    if blank?(client_id) do
      {:error, :client_id_not_configured}
    else
      state = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
      redirect_uri = get_redirect_uri()

      TokenManager.put_state(state, owner)

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

  @doc """
  Handle the OAuth callback for `owner` (the signed-in session's
  fingerprint) — exchange the code for tokens. A state issued to another
  session is refused, and spent.
  """
  @spec handle_callback(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, atom()}
  def handle_callback(code, state, owner) do
    # Lookup and delete happen together inside TokenManager, so a state cannot
    # be redeemed twice by two callbacks arriving at once.
    case TokenManager.take_state(state) do
      {:ok, ^owner} -> exchange_code(code, owner)
      {:ok, _other} -> {:error, :invalid_state}
      :expired -> {:error, :state_expired}
      :error -> {:error, :invalid_state}
    end
  end

  @doc "Disconnect Google — remove the stored refresh token from OpenBao."
  @spec disconnect() :: :ok | {:error, term()}
  def disconnect do
    with :ok <- Config.clear("google.oauth.refresh_token") do
      Logger.info("Google OAuth disconnected")
      :ok
    end
  end

  @doc "Check if Google OAuth is connected."
  @spec connected?() :: boolean()
  def connected? do
    Config.secret_set?("google.oauth.refresh_token")
  end

  # --- Internal ---

  defp exchange_code(code, owner) do
    client_id = Config.get("google.oauth.client_id")
    client_secret = Config.secret_value("google.oauth.client_secret")
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

        TokenManager.refresh()

        Logger.info("Google OAuth connected successfully")
        {:ok, owner}

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
end
