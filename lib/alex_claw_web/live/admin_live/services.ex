defmodule AlexClawWeb.AdminLive.Services do
  @moduledoc "LiveView page for monitoring external service status."

  use Phoenix.LiveView
  require Logger

  alias AlexClaw.Auth.{Challenge, CodeEntry, RecoveryCodes, TOTP}
  alias AlexClaw.Config
  alias AlexClaw.Gateway.Discord
  alias AlexClaw.Gateway.Telegram
  alias AlexClaw.Google.TokenManager
  alias AlexClawWeb.Live.Elevation
  alias Ecto.Adapters.SQL
  alias Nostrum.Api.Message

  @telegram_api "https://api.telegram.org/bot"

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(AlexClaw.PubSub, "services:totp")
    end

    {:ok,
     socket
     |> Elevation.assign_elevation(session)
     |> assign(
       page_title: "Services",
       services: build_services(),
       totp_setup: nil,
       totp_message: nil,
       recovery_codes: nil,
       recovery: RecoveryCodes.status()
     )}
  end

  @impl true
  def handle_info({:elevation, _state, _detail} = message, socket) do
    {:noreply, Elevation.handle_broadcast(socket, message)}
  end

  def handle_info({:totp_verified, _action}, socket) do
    services =
      Enum.map(socket.assigns.services, fn svc ->
        if svc.id == "totp", do: %{svc | status: :connected, detail: "Code verified"}, else: svc
      end)

    {:noreply, assign(socket, services: services)}
  end

  # Setting 2FA up needs the admin password and nothing else. Requiring a second
  # factor to configure the second factor is the circle this whole design exists
  # to break, and adding protection is not a privileged act.
  @impl true
  def handle_event("setup_2fa", _params, socket) do
    {:ok, %{uri: uri, qr_png: qr_png}} = TOTP.setup()

    {:noreply,
     assign(socket,
       totp_setup: %{uri: uri, qr: Base.encode64(qr_png), key: manual_key(uri)},
       totp_message: nil
     )}
  end

  def handle_event("confirm_2fa", %{"code" => code}, socket) do
    {:noreply, confirmed(TOTP.confirm_setup(String.trim(code)), socket)}
  end

  def handle_event("cancel_2fa_setup", _params, socket) do
    Config.delete("auth.totp.pending_secret")
    {:noreply, assign(socket, totp_setup: nil, totp_message: nil)}
  end

  # Turning 2FA off is the one thing an elevation must never cover: a window
  # opened an hour of typing ago should not be able to remove the factor that
  # opened it.
  def handle_event("disable_2fa", %{"code" => code}, socket) do
    {:noreply, disabled(CodeEntry.verify(sid(socket), code, :web), socket)}
  end

  @impl true
  def handle_event("check", %{"service" => service}, socket) do
    result = live_check(service)

    services =
      Enum.map(socket.assigns.services, fn svc ->
        if svc.id == service, do: %{svc | status: result.status, detail: result.detail}, else: svc
      end)

    {:noreply, assign(socket, services: services)}
  end

  @impl true
  def handle_event("reembed", _params, socket) do
    {:ok, mem_count} = AlexClaw.Memory.reembed_all(batch_size: 20, max_concurrency: 2)
    {:ok, kb_count} = AlexClaw.Knowledge.reembed_all(batch_size: 20, max_concurrency: 2)
    total = mem_count + kb_count

    if total > 0, do: schedule_reembed_check()

    services =
      Enum.map(socket.assigns.services, fn svc ->
        if svc.id == "embeddings",
          do: %{svc | status: :challenged, detail: reembed_detail(total)},
          else: svc
      end)

    {:noreply, assign(socket, services: services)}
  end

  # Shown once, and only here. Acknowledging clears them from the page; there
  # is no second chance to read them, which is what makes "save these" a real
  # instruction rather than a suggestion.
  def handle_event("saved_recovery_codes", _params, socket) do
    {:noreply, assign(socket, recovery_codes: nil)}
  end

  # A fresh set invalidates the old one, so it answers to a code like any other
  # change to the second factor.
  def handle_event("regenerate_recovery_codes", %{"code" => code}, socket) do
    {:noreply, regenerated(CodeEntry.verify(sid(socket), code, :web), socket)}
  end

  defp reembed_detail(0), do: "Nothing to re-embed"
  defp reembed_detail(total), do: "Re-embedding #{total} entries in background..."

  @impl true
  def handle_info(:reembed_check, socket) do
    result = live_check("embeddings")

    services =
      Enum.map(socket.assigns.services, fn svc ->
        if svc.id == "embeddings",
          do: %{svc | status: result.status, detail: result.detail},
          else: svc
      end)

    if result.status == :expired or result.status == :challenged do
      schedule_reembed_check()
    end

    {:noreply, assign(socket, services: services)}
  end

  defp schedule_reembed_check, do: Process.send_after(self(), :reembed_check, 10_000)

  # --- Initial status (config-level, no side effects) ---

  defp build_services do
    [
      %{
        id: "database",
        name: "Database",
        icon: "🗄️",
        status: initial_status("database"),
        detail: nil,
        config_url: "/config"
      },
      %{
        id: "google",
        name: "Google API",
        icon: "🔗",
        status: initial_status("google"),
        detail: nil,
        config_url: "/config"
      },
      %{
        id: "telegram",
        name: "Telegram Bot",
        icon: "📨",
        status: initial_status("telegram"),
        detail: nil,
        config_url: "/config"
      },
      %{
        id: "discord",
        name: "Discord Bot",
        icon: "🎮",
        status: initial_status("discord"),
        detail: nil,
        config_url: "/config"
      },
      %{
        id: "totp",
        name: "2FA (TOTP)",
        icon: "🔐",
        status: initial_status("totp"),
        detail: nil,
        config_url: "/config"
      },
      %{
        id: "ollama",
        name: "Ollama",
        icon: "🦙",
        status: initial_status("ollama"),
        detail: nil,
        config_url: "/config"
      },
      %{
        id: "lmstudio",
        name: "LM Studio",
        icon: "🧠",
        status: initial_status("lmstudio"),
        detail: nil,
        config_url: "/config"
      },
      %{
        id: "github",
        name: "GitHub API",
        icon: "🐙",
        status: initial_status("github"),
        detail: nil,
        config_url: "/config"
      },
      %{
        id: "web_automator",
        name: "Web Automator",
        icon: "🌐",
        status: initial_status("web_automator"),
        detail: nil,
        config_url: "/config"
      },
      %{
        id: "embeddings",
        name: "Embeddings",
        icon: "📐",
        status: initial_status("embeddings"),
        detail: nil,
        config_url: "/config"
      }
    ]
  end

  defp initial_status("database") do
    case SQL.query(AlexClaw.Repo, "SELECT 1") do
      {:ok, _} -> :connected
      {:error, _} -> :error
    end
  end

  defp initial_status("google"), do: TokenManager.status()

  defp initial_status("telegram") do
    if Telegram.configured?(), do: :configured, else: :not_configured
  end

  defp initial_status("discord") do
    if Discord.configured?(), do: :configured, else: :not_configured
  end

  defp initial_status("totp") do
    if TOTP.enabled?(), do: :configured, else: :not_configured
  end

  defp initial_status("ollama") do
    enabled = Config.get("llm.ollama_enabled")
    if enabled in [true, "true"], do: :configured, else: :not_configured
  end

  defp initial_status("lmstudio") do
    enabled = Config.get("llm.lmstudio_enabled")
    if enabled in [true, "true"], do: :configured, else: :not_configured
  end

  defp initial_status("github") do
    token = Config.get("github.token")
    if token && token != "", do: :configured, else: :not_configured
  end

  defp initial_status("web_automator") do
    enabled = Config.get("web_automator.enabled")
    if enabled in [true, "true"], do: :configured, else: :not_configured
  end

  defp initial_status("embeddings") do
    model = Config.get("embedding.model")
    if model && model != "", do: :configured, else: :not_configured
  end

  defp initial_status(_), do: :error

  # --- Live checks (real connectivity tests) ---

  # The secret as the authenticator shows it, for typing in by hand when a
  # camera is not an option.
  defp manual_key(uri) do
    uri
    |> URI.parse()
    |> Map.get(:query)
    |> URI.decode_query()
    |> Map.get("secret", "")
  end

  defp sid(%{assigns: %{elevation_sid: sid}}), do: sid
  defp sid(_socket), do: nil

  # The codes exist in readable form for exactly this render. They are shown
  # once, and the operator confirms they have them before the page lets go.
  defp confirmed(:ok, socket) do
    socket
    |> assign(
      totp_setup: nil,
      totp_message: nil,
      recovery_codes: RecoveryCodes.generate(),
      recovery: RecoveryCodes.status(),
      services: build_services(),
      # The badge and the setup button both read this. Without refreshing it the
      # page keeps claiming 2FA is off directly after turning it on.
      elevation: %{socket.assigns.elevation | configured?: AlexClaw.Auth.Elevation.configured?()}
    )
    |> put_flash(:info, "Two-factor authentication is on. Save your recovery codes.")
  end

  defp confirmed({:error, :invalid_code}, socket) do
    assign(socket, totp_message: "That code is not valid. Try the next one.")
  end

  defp confirmed({:error, :no_pending_setup}, socket) do
    assign(socket, totp_setup: nil, totp_message: "That setup expired. Start again.")
  end

  defp regenerated(:ok, socket) do
    socket
    |> assign(recovery_codes: RecoveryCodes.generate(), totp_message: nil)
    |> assign(recovery: RecoveryCodes.status())
    |> put_flash(:info, "New recovery codes. The old ones no longer work.")
  end

  defp regenerated({:error, _reason}, socket) do
    assign(socket, totp_message: "That code is not valid. The codes are unchanged.")
  end

  defp disabled(:ok, socket) do
    TOTP.disable()
    RecoveryCodes.discard()

    socket
    |> assign(services: build_services(), totp_message: nil, recovery: RecoveryCodes.status())
    |> put_flash(:info, "Two-factor authentication is off. The control plane is read-only.")
  end

  defp disabled({:error, _reason}, socket) do
    assign(socket, totp_message: "That code is not valid. 2FA is unchanged.")
  end

  defp live_check("database") do
    case SQL.query(AlexClaw.Repo, "SELECT 1") do
      {:ok, _} -> %{status: :connected, detail: "Query OK"}
      {:error, reason} -> %{status: :error, detail: inspect(reason)}
    end
  end

  defp live_check("google") do
    status = TokenManager.status()

    detail =
      case status do
        :connected -> "Token valid"
        :expired -> "Token expired — re-authenticate"
        :not_configured -> "Credentials not set"
        _ -> "Unable to verify"
      end

    %{status: status, detail: detail}
  end

  defp live_check("telegram") do
    telegram_check(
      Config.enabled?("telegram.enabled"),
      Config.get("telegram.bot_token"),
      Config.get("telegram.chat_id")
    )
  end

  defp live_check("discord") do
    discord_check(
      Config.enabled?("discord.enabled"),
      Config.get("discord.bot_token"),
      Config.get("discord.channel_id")
    )
  end

  defp live_check("totp") do
    if TOTP.enabled?() do
      chat_id = Config.get("telegram.chat_id")

      if chat_id && chat_id != "" do
        action = %{type: :service_check, description: "2FA connectivity check from Services page"}
        Challenge.create(chat_id, action)

        Telegram.send_message(
          "2FA check from Services page.\n\nEnter your 6-digit authenticator code:"
        )

        %{status: :challenged, detail: "Challenge sent — reply with your code on Telegram"}
      else
        %{status: :error, detail: "Telegram chat ID not configured — cannot send challenge"}
      end
    else
      %{status: :not_configured, detail: "TOTP not enabled"}
    end
  end

  defp live_check("ollama") do
    host = Config.get("llm.ollama_host") || "http://localhost:11434"
    ollama_status(Config.enabled?("llm.ollama_enabled"), host)
  end

  defp live_check("lmstudio") do
    host = Config.get("llm.lmstudio_host") || "http://host.docker.internal:1234"
    lmstudio_status(Config.enabled?("llm.lmstudio_enabled"), host)
  end

  defp live_check("github") do
    token = Config.get("github.token")

    if !token || token == "" do
      %{status: :not_configured, detail: "Token not set"}
    else
      case Req.get("https://api.github.com/user",
             headers: [
               {"authorization", "Bearer #{token}"},
               {"accept", "application/vnd.github+json"}
             ],
             receive_timeout: 5_000
           ) do
        {:ok, %{status: 200, body: %{"login" => login}}} ->
          %{status: :connected, detail: "Authenticated as #{login}"}

        {:ok, %{status: 401}} ->
          %{status: :error, detail: "Token invalid or expired"}

        {:ok, %{status: s}} ->
          %{status: :error, detail: "HTTP #{s}"}

        {:error, reason} ->
          %{status: :error, detail: inspect(reason)}
      end
    end
  end

  defp live_check("web_automator") do
    host = Config.get("web_automator.host") || "http://web-automator:6900"
    web_automator_status(Config.enabled?("web_automator.enabled"), host)
  end

  defp live_check("embeddings") do
    model = Config.get("embedding.model")

    if !model || model == "" do
      %{status: :not_configured, detail: "No embedding model configured"}
    else
      stale_mem = AlexClaw.Memory.stale_embedding_count(model)
      stale_kb = AlexClaw.Knowledge.stale_embedding_count(model)
      total_stale = stale_mem + stale_kb

      if total_stale == 0 do
        %{status: :connected, detail: "All embeddings use #{model}"}
      else
        %{
          status: :expired,
          detail:
            "#{total_stale} stale embeddings (#{stale_mem} memory, #{stale_kb} knowledge) — model: #{model}"
        }
      end
    end
  end

  defp live_check(_), do: %{status: :error, detail: "Unknown service"}

  defp telegram_check(false, _token, _chat_id),
    do: %{status: :not_configured, detail: "Gateway disabled"}

  defp telegram_check(true, token, _chat_id) when token in [nil, ""],
    do: %{status: :not_configured, detail: "Bot token not set"}

  defp telegram_check(true, _token, chat_id) when chat_id in [nil, ""],
    do: %{status: :not_configured, detail: "Chat ID not set"}

  defp telegram_check(true, token, chat_id) do
    "#{@telegram_api}#{token}/sendMessage"
    |> Req.post(json: %{chat_id: chat_id, text: "🦇 AlexClaw connectivity check"})
    |> telegram_result()
  end

  defp telegram_result({:ok, %{status: 200}}),
    do: %{status: :connected, detail: "Message delivered"}

  defp telegram_result({:ok, %{status: status, body: body}}),
    do: %{status: :error, detail: "HTTP #{status}: #{inspect(body)}"}

  defp telegram_result({:error, reason}), do: %{status: :error, detail: inspect(reason)}

  defp discord_check(false, _token, _channel_id),
    do: %{status: :not_configured, detail: "Gateway disabled"}

  defp discord_check(true, token, _channel_id) when token in [nil, ""],
    do: %{status: :not_configured, detail: "Bot token not set"}

  defp discord_check(true, _token, channel_id) when channel_id in [nil, ""],
    do: %{status: :not_configured, detail: "Channel ID not set"}

  defp discord_check(true, _token, channel_id) do
    channel_id
    |> discord_channel_id()
    |> Message.create(content: "🦇 AlexClaw connectivity check")
    |> discord_result()
  end

  defp discord_channel_id(channel_id) do
    case Integer.parse(to_string(channel_id)) do
      {n, _} -> n
      :error -> channel_id
    end
  end

  defp discord_result({:ok, _msg}), do: %{status: :connected, detail: "Message delivered"}
  defp discord_result({:error, reason}), do: %{status: :error, detail: inspect(reason)}

  defp ollama_status(false, _host), do: %{status: :not_configured, detail: "Ollama disabled"}

  defp ollama_status(true, host) do
    case Req.get("#{host}/api/tags", receive_timeout: 5_000) do
      {:ok, %{status: 200, body: %{"models" => models}}} ->
        names = Enum.map_join(models, ", ", & &1["name"])
        %{status: :connected, detail: "#{length(models)} model(s): #{names}"}

      {:ok, %{status: s}} ->
        %{status: :error, detail: "HTTP #{s}"}

      {:error, reason} ->
        %{status: :error, detail: inspect(reason)}
    end
  end

  defp lmstudio_status(false, _host), do: %{status: :not_configured, detail: "LM Studio disabled"}

  defp lmstudio_status(true, host) do
    case Req.get("#{host}/v1/models", receive_timeout: 5_000) do
      {:ok, %{status: 200, body: %{"data" => models}}} ->
        names = Enum.map_join(models, ", ", & &1["id"])
        %{status: :connected, detail: "#{length(models)} model(s): #{names}"}

      {:ok, %{status: s}} ->
        %{status: :error, detail: "HTTP #{s}"}

      {:error, reason} ->
        %{status: :error, detail: inspect(reason)}
    end
  end

  defp web_automator_status(false, _host) do
    %{status: :not_configured, detail: "Web Automator disabled"}
  end

  defp web_automator_status(true, host) do
    case Req.get("#{host}/status", receive_timeout: 5_000) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        %{status: :connected, detail: "Sidecar running"}

      {:ok, %{status: 200}} ->
        %{status: :connected, detail: "Sidecar running"}

      {:ok, %{status: s}} ->
        %{status: :error, detail: "HTTP #{s}"}

      {:error, reason} ->
        %{status: :error, detail: inspect(reason)}
    end
  end

  # --- View helpers ---

  defp status_label(:connected), do: "Connected"
  defp status_label(:configured), do: "Configured"
  defp status_label(:challenged), do: "Waiting for code"
  defp status_label(:expired), do: "Expired"
  defp status_label(:not_configured), do: "Not configured"
  defp status_label(:error), do: "Error"
  defp status_label(_), do: "Unknown"

  defp status_classes(:connected), do: "bg-green-900 text-green-300"
  defp status_classes(:configured), do: "bg-blue-900 text-blue-300"
  defp status_classes(:challenged), do: "bg-yellow-900 text-yellow-300"
  defp status_classes(:expired), do: "bg-yellow-900 text-yellow-300"
  defp status_classes(:not_configured), do: "bg-gray-800 text-gray-500"
  defp status_classes(:error), do: "bg-red-900 text-red-300"
  defp status_classes(_), do: "bg-gray-800 text-gray-500"
end
