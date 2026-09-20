defmodule AlexClaw.Dispatcher.AuthCommands do
  @moduledoc "Handles 2FA setup/confirm/disable, OAuth connect/disconnect, and 2FA challenge flow."
  require Logger

  alias AlexClaw.Auth.{Elevation, TOTP}
  alias AlexClaw.Database.Restore
  alias AlexClaw.Gateway
  alias AlexClaw.Gateway.Router
  alias AlexClaw.Google.OAuth
  alias AlexClaw.Message
  alias AlexClaw.Skills.Shell
  alias AlexClaw.Workflows.{Executor, SkillRegistry}

  @spec dispatch(Message.t()) :: :ok | term()

  # --- 2FA Setup ---

  def dispatch(%Message{text: "/setup 2fa" <> _} = msg) do
    case TOTP.setup() do
      {:ok, %{secret: secret, qr_png: qr_png}} ->
        secret_b32 = Base.encode32(secret, padding: false)

        Router.send_photo(
          msg.chat_id,
          qr_png,
          "Scan from another device, or use the manual key below.",
          gateway: msg.gateway
        )

        Gateway.send_message(
          "Manual setup key (tap to copy):\n`#{secret_b32}`\n\nIn Google Authenticator: + > Enter setup key\nAccount: AlexClaw\nKey: paste the code above\nType: Time-based\n\nThen confirm with: /confirm 2fa <6-digit code>",
          chat_id: msg.chat_id,
          gateway: msg.gateway
        )
    end
  end

  def dispatch(%Message{text: "/confirm 2fa " <> code} = msg) do
    case TOTP.confirm_setup(String.trim(code)) do
      :ok ->
        Gateway.send_message(
          "2FA enabled! Sensitive actions will now require a code from your authenticator app.",
          chat_id: msg.chat_id,
          gateway: msg.gateway
        )

      {:error, :invalid_code} ->
        Gateway.send_message("Invalid code. Try again: /confirm 2fa <code>",
          chat_id: msg.chat_id,
          gateway: msg.gateway
        )

      {:error, :no_pending_setup} ->
        Gateway.send_message("No pending 2FA setup. Start with /setup 2fa",
          chat_id: msg.chat_id,
          gateway: msg.gateway
        )
    end
  end

  def dispatch(%Message{text: "/disable 2fa " <> code} = msg) do
    disable_2fa(msg, TOTP.enabled?(), String.trim(code))
  end

  def dispatch(%Message{text: "/disable 2fa" <> _} = msg) do
    disable_2fa(msg, TOTP.enabled?(), "")
  end

  # --- OAuth ---

  def dispatch(%Message{text: "/connect google" <> _} = msg) do
    case OAuth.generate_auth_url(msg.chat_id) do
      {:ok, url} ->
        Gateway.send_html(
          "<b>Connect Google Calendar</b>\n\nTap the link below to authorize:\n\n#{url}\n\n<i>This link expires in 10 minutes.</i>",
          chat_id: msg.chat_id,
          gateway: msg.gateway
        )

      {:error, :client_id_not_configured} ->
        Gateway.send_message(
          "Google OAuth not configured. Set google.oauth.client_id and google.oauth.client_secret in Admin > Config first.",
          chat_id: msg.chat_id,
          gateway: msg.gateway
        )
    end
  end

  def dispatch(%Message{text: "/disconnect google" <> _} = msg) do
    OAuth.disconnect()

    Gateway.send_message("Google disconnected. Refresh token removed.",
      chat_id: msg.chat_id,
      gateway: msg.gateway
    )
  end

  def dispatch(%Message{text: "/connect" <> _} = msg) do
    Gateway.send_message(
      "Available services:\n/connect google — Google Calendar",
      chat_id: msg.chat_id,
      gateway: msg.gateway
    )
  end

  # Disabling 2FA is itself a sensitive action: without a current code, anyone who
  # can reach the gateway could turn the second factor off and then act freely.
  defp disable_2fa(msg, false, _code) do
    Gateway.send_message("2FA is not enabled.", chat_id: msg.chat_id, gateway: msg.gateway)
  end

  defp disable_2fa(msg, true, "") do
    Gateway.send_message(
      "Disabling 2FA requires your current code:\n/disable 2fa <6-digit code>",
      chat_id: msg.chat_id,
      gateway: msg.gateway
    )
  end

  defp disable_2fa(msg, true, code) do
    disable_verified(msg, TOTP.verify(code))
  end

  defp disable_verified(msg, true) do
    TOTP.disable()
    Gateway.send_message("2FA disabled.", chat_id: msg.chat_id, gateway: msg.gateway)
  end

  defp disable_verified(msg, false) do
    Logger.warning("Rejected /disable 2fa: invalid code", auth: :denied)

    Gateway.send_message(
      "Invalid code. 2FA is still enabled.",
      chat_id: msg.chat_id,
      gateway: msg.gateway
    )
  end

  # --- 2FA Helpers ---

  @doc """
  Wraps a sensitive action with a 2FA challenge.

  Returns `:challenged` once the code has been requested, or `:no_2fa` when TOTP
  is not configured. Callers must treat `:no_2fa` as a refusal — the action is
  not performed.
  """
  @spec require_2fa(Message.t(), map(), String.t()) :: :challenged | :no_2fa
  def require_2fa(msg, action, description) do
    challenge_2fa(msg, action, description, TOTP.enabled?())
  end

  # Fail closed: an action that asked for a second factor is refused when there is
  # no second factor to ask for, rather than running unprotected.
  defp challenge_2fa(_msg, _action, _description, false), do: :no_2fa

  defp challenge_2fa(msg, action, description, true) do
    TOTP.create_challenge(msg.chat_id, action)

    Gateway.send_message(
      "This action requires 2FA verification.\n#{description}\n\nEnter your 6-digit authenticator code:",
      chat_id: msg.chat_id,
      gateway: msg.gateway
    )

    :challenged
  end

  @spec execute_2fa_action(map(), Message.t()) :: term()
  def execute_2fa_action(%{type: :run_workflow, workflow_id: id}, _msg) do
    Task.Supervisor.start_child(AlexClaw.TaskSupervisor, fn ->
      Executor.run(id)
    end)
  end

  def execute_2fa_action(%{type: :shell_command, command: command}, msg) do
    Task.Supervisor.start_child(AlexClaw.TaskSupervisor, fn ->
      case Shell.run(%{input: command}) do
        {:ok, result, _branch} ->
          Gateway.send_message(result, gateway: msg.gateway)

        {:error, reason} ->
          Gateway.send_message("Shell error: #{inspect(reason)}", gateway: msg.gateway)
      end
    end)
  end

  # The file waits in skills_dir/pending until the code is verified; only now does
  # it become a file the loader will resolve. A generated skill that reached this
  # point failed containment, so the verified code is what authorises it.
  def execute_2fa_action(%{type: :skill_load, file_path: file_path} = action, _msg) do
    case SkillRegistry.promote_pending(file_path) do
      {:error, reason} ->
        Gateway.send_message("Skill load failed: #{SkillRegistry.describe_error(reason)}")

      _promoted ->
        report_load(SkillRegistry.load_skill(file_path, load_opts(action)))
    end
  end

  # The window starts when the code is accepted, not when it was requested.
  def execute_2fa_action(%{type: :elevate, sid: sid}, _msg) do
    {:ok, expires_at} = Elevation.grant(sid)
    minutes = div(Elevation.window_seconds(), 60)

    Gateway.send_message(
      "Admin editing unlocked for #{minutes} minutes (until #{format_time(expires_at)} UTC)."
    )
  end

  def execute_2fa_action(%{type: :skill_unload, name: name}, _msg) do
    case SkillRegistry.unload_skill(name) do
      :ok ->
        Gateway.send_message("Skill *#{name}* unloaded.")

      {:error, reason} ->
        Gateway.send_message("Skill unload failed: #{SkillRegistry.describe_error(reason)}")
    end
  end

  def execute_2fa_action(%{type: :skill_reload, name: name}, _msg) do
    case SkillRegistry.reload_skill(name) do
      {:ok, %{name: n}} ->
        Gateway.send_message("Skill *#{n}* reloaded and recompiled.")

      {:error, reason} ->
        Gateway.send_message("Skill reload failed: #{SkillRegistry.describe_error(reason)}")
    end
  end

  # Arbitrary SQL against the live database, so it is never covered by an
  # elevation window — only by a code answered for this restore. The staged
  # file is consumed either way: Restore.run/1 deletes it.
  def execute_2fa_action(%{type: :database_restore, path: path, filename: filename}, _msg) do
    Gateway.send_message("Restoring the database from #{filename}...")

    {status, message} = Restore.run(path)

    Phoenix.PubSub.broadcast(
      AlexClaw.PubSub,
      "database:restore",
      {:restore_finished, status, message}
    )

    Gateway.send_message(message)
  end

  def execute_2fa_action(action, msg) do
    Logger.warning("Unknown 2FA action: #{inspect(action)}")
    Gateway.send_message("Action completed.", chat_id: msg.chat_id, gateway: msg.gateway)
  end

  defp report_load({:ok, %{name: name, permissions: perms}}) do
    perm_list = Enum.map_join(perms, ", ", &to_string/1)
    Gateway.send_message("Skill *#{name}* loaded. Permissions: [#{perm_list}]")
  end

  defp report_load({:error, reason}) do
    Gateway.send_message("Skill load failed: #{SkillRegistry.describe_error(reason)}")
  end

  defp load_opts(%{origin: :generated}), do: [origin: "generated", approval: "totp"]
  defp load_opts(_action), do: [origin: "upload", approval: "totp"]

  defp format_time(unix_seconds) do
    unix_seconds
    |> DateTime.from_unix!()
    |> Calendar.strftime("%H:%M")
  end
end
