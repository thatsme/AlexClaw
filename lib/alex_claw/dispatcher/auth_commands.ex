defmodule AlexClaw.Dispatcher.AuthCommands do
  @moduledoc "Handles 2FA setup/confirm/disable, OAuth connect/disconnect, and 2FA challenge flow."
  require Logger

  alias AlexClaw.{Gateway, Message}

  # --- 2FA Setup ---

  def dispatch(%Message{text: "/setup 2fa" <> _} = msg) do
    case AlexClaw.Auth.TOTP.setup() do
      {:ok, %{secret: secret, qr_png: qr_png}} ->
        secret_b32 = Base.encode32(secret, padding: false)

        AlexClaw.Gateway.Router.send_photo(msg.chat_id, qr_png, "Scan from another device, or use the manual key below.", gateway: msg.gateway)

        Gateway.send_message(
          "Manual setup key (tap to copy):\n`#{secret_b32}`\n\nIn Google Authenticator: + > Enter setup key\nAccount: AlexClaw\nKey: paste the code above\nType: Time-based\n\nThen confirm with: /confirm 2fa <6-digit code>",
          chat_id: msg.chat_id, gateway: msg.gateway
        )
    end
  end

  def dispatch(%Message{text: "/confirm 2fa " <> code} = msg) do
    case AlexClaw.Auth.TOTP.confirm_setup(String.trim(code)) do
      :ok ->
        Gateway.send_message("2FA enabled! Sensitive actions will now require a code from your authenticator app.", chat_id: msg.chat_id, gateway: msg.gateway)

      {:error, :invalid_code} ->
        Gateway.send_message("Invalid code. Try again: /confirm 2fa <code>", chat_id: msg.chat_id, gateway: msg.gateway)

      {:error, :no_pending_setup} ->
        Gateway.send_message("No pending 2FA setup. Start with /setup 2fa", chat_id: msg.chat_id, gateway: msg.gateway)
    end
  end

  def dispatch(%Message{text: "/disable 2fa" <> _} = msg) do
    if AlexClaw.Auth.TOTP.enabled?() do
      AlexClaw.Auth.TOTP.disable()
      Gateway.send_message("2FA disabled.", chat_id: msg.chat_id, gateway: msg.gateway)
    else
      Gateway.send_message("2FA is not enabled.", chat_id: msg.chat_id, gateway: msg.gateway)
    end
  end

  # --- OAuth ---

  def dispatch(%Message{text: "/connect google" <> _} = msg) do
    case AlexClaw.Google.OAuth.generate_auth_url(msg.chat_id) do
      {:ok, url} ->
        Gateway.send_html(
          "<b>Connect Google Calendar</b>\n\nTap the link below to authorize:\n\n#{url}\n\n<i>This link expires in 10 minutes.</i>",
          chat_id: msg.chat_id, gateway: msg.gateway
        )

      {:error, :client_id_not_configured} ->
        Gateway.send_message(
          "Google OAuth not configured. Set google.oauth.client_id and google.oauth.client_secret in Admin > Config first.",
          chat_id: msg.chat_id, gateway: msg.gateway
        )
    end
  end

  def dispatch(%Message{text: "/disconnect google" <> _} = msg) do
    AlexClaw.Google.OAuth.disconnect()
    Gateway.send_message("Google disconnected. Refresh token removed.", chat_id: msg.chat_id, gateway: msg.gateway)
  end

  def dispatch(%Message{text: "/connect" <> _} = msg) do
    Gateway.send_message(
      "Available services:\n/connect google — Google Calendar",
      chat_id: msg.chat_id, gateway: msg.gateway
    )
  end

  # --- 2FA Helpers ---

  @doc """
  Wraps a sensitive action with 2FA challenge if enabled.
  If 2FA is not enabled, executes immediately.
  """
  def require_2fa(msg, action, description) do
    if AlexClaw.Auth.TOTP.enabled?() do
      AlexClaw.Auth.TOTP.create_challenge(msg.chat_id, action)
      Gateway.send_message(
        "This action requires 2FA verification.\n#{description}\n\nEnter your 6-digit authenticator code:",
        chat_id: msg.chat_id, gateway: msg.gateway
      )
      :challenged
    else
      :proceed
    end
  end

  def execute_2fa_action(%{type: :run_workflow, workflow_id: id}, _msg) do
    Task.Supervisor.start_child(AlexClaw.TaskSupervisor, fn -> AlexClaw.Workflows.Executor.run(id) end)
  end

  def execute_2fa_action(%{type: :shell_command, command: command}, msg) do
    Task.Supervisor.start_child(AlexClaw.TaskSupervisor, fn ->
      case AlexClaw.Skills.Shell.run(%{input: command}) do
        {:ok, result, _branch} -> Gateway.send_message(result, gateway: msg.gateway)
        {:error, reason} -> Gateway.send_message("Shell error: #{inspect(reason)}", gateway: msg.gateway)
      end
    end)
  end

  def execute_2fa_action(action, msg) do
    Logger.warning("Unknown 2FA action: #{inspect(action)}")
    Gateway.send_message("Action completed.", chat_id: msg.chat_id, gateway: msg.gateway)
  end
end
