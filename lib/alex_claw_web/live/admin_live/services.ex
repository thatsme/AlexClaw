defmodule AlexClawWeb.AdminLive.Services do
  @moduledoc "LiveView page for monitoring external service status."

  use Phoenix.LiveView
  require Logger

  alias AlexClaw.Config

  @telegram_api "https://api.telegram.org/bot"

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(AlexClaw.PubSub, "services:totp")
    end

    {:ok, assign(socket, page_title: "Services", services: build_services())}
  end

  @impl true
  def handle_info({:totp_verified, _action}, socket) do
    services =
      Enum.map(socket.assigns.services, fn svc ->
        if svc.id == "totp", do: %{svc | status: :connected, detail: "Code verified"}, else: svc
      end)

    {:noreply, assign(socket, services: services)}
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

    services =
      Enum.map(socket.assigns.services, fn svc ->
        if svc.id == "embeddings" do
          detail = if total > 0, do: "Re-embedding #{total} entries in background...", else: "Nothing to re-embed"
          %{svc | status: :challenged, detail: detail}
        else
          svc
        end
      end)

    {:noreply, assign(socket, services: services)}
  end

  # --- Initial status (config-level, no side effects) ---

  defp build_services do
    [
      %{id: "database", name: "Database", icon: "🗄️", status: initial_status("database"), detail: nil, config_url: "/config"},
      %{id: "google", name: "Google API", icon: "🔗", status: initial_status("google"), detail: nil, config_url: "/config"},
      %{id: "telegram", name: "Telegram Bot", icon: "📨", status: initial_status("telegram"), detail: nil, config_url: "/config"},
      %{id: "discord", name: "Discord Bot", icon: "🎮", status: initial_status("discord"), detail: nil, config_url: "/config"},
      %{id: "totp", name: "2FA (TOTP)", icon: "🔐", status: initial_status("totp"), detail: nil, config_url: "/config"},
      %{id: "ollama", name: "Ollama", icon: "🦙", status: initial_status("ollama"), detail: nil, config_url: "/config"},
      %{id: "lmstudio", name: "LM Studio", icon: "🧠", status: initial_status("lmstudio"), detail: nil, config_url: "/config"},
      %{id: "github", name: "GitHub API", icon: "🐙", status: initial_status("github"), detail: nil, config_url: "/config"},
      %{id: "web_automator", name: "Web Automator", icon: "🌐", status: initial_status("web_automator"), detail: nil, config_url: "/config"},
      %{id: "embeddings", name: "Embeddings", icon: "📐", status: initial_status("embeddings"), detail: nil, config_url: "/config"}
    ]
  end

  defp initial_status("database") do
    case Ecto.Adapters.SQL.query(AlexClaw.Repo, "SELECT 1") do
      {:ok, _} -> :connected
      {:error, _} -> :error
    end
  end

  defp initial_status("google"), do: AlexClaw.Google.TokenManager.status()

  defp initial_status("telegram") do
    if AlexClaw.Gateway.Telegram.configured?(), do: :configured, else: :not_configured
  end

  defp initial_status("discord") do
    if AlexClaw.Gateway.Discord.configured?(), do: :configured, else: :not_configured
  end

  defp initial_status("totp") do
    if AlexClaw.Auth.TOTP.enabled?(), do: :configured, else: :not_configured
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

  defp live_check("database") do
    case Ecto.Adapters.SQL.query(AlexClaw.Repo, "SELECT 1") do
      {:ok, _} -> %{status: :connected, detail: "Query OK"}
      {:error, reason} -> %{status: :error, detail: inspect(reason)}
    end
  end

  defp live_check("google") do
    status = AlexClaw.Google.TokenManager.status()

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
    token = Config.get("telegram.bot_token")
    chat_id = Config.get("telegram.chat_id")
    enabled = Config.get("telegram.enabled")

    cond do
      enabled not in [true, "true"] ->
        %{status: :not_configured, detail: "Gateway disabled"}

      !token || token == "" ->
        %{status: :not_configured, detail: "Bot token not set"}

      !chat_id || chat_id == "" ->
        %{status: :not_configured, detail: "Chat ID not set"}

      true ->
        url = "#{@telegram_api}#{token}/sendMessage"

        case Req.post(url, json: %{chat_id: chat_id, text: "🦇 AlexClaw connectivity check"}) do
          {:ok, %{status: 200}} ->
            %{status: :connected, detail: "Message delivered"}

          {:ok, %{status: s, body: body}} ->
            %{status: :error, detail: "HTTP #{s}: #{inspect(body)}"}

          {:error, reason} ->
            %{status: :error, detail: inspect(reason)}
        end
    end
  end

  defp live_check("discord") do
    enabled = Config.get("discord.enabled")
    token = Config.get("discord.bot_token")
    channel_id = Config.get("discord.channel_id")

    cond do
      enabled not in [true, "true"] ->
        %{status: :not_configured, detail: "Gateway disabled"}

      !token || token == "" ->
        %{status: :not_configured, detail: "Bot token not set"}

      !channel_id || channel_id == "" ->
        %{status: :not_configured, detail: "Channel ID not set"}

      true ->
        channel_int =
          case Integer.parse(to_string(channel_id)) do
            {n, _} -> n
            :error -> channel_id
          end

        case Nostrum.Api.Message.create(channel_int, content: "🦇 AlexClaw connectivity check") do
          {:ok, _msg} ->
            %{status: :connected, detail: "Message delivered"}

          {:error, reason} ->
            %{status: :error, detail: inspect(reason)}
        end
    end
  end

  defp live_check("totp") do
    if AlexClaw.Auth.TOTP.enabled?() do
      chat_id = Config.get("telegram.chat_id")

      if chat_id && chat_id != "" do
        action = %{type: :service_check, description: "2FA connectivity check from Services page"}
        AlexClaw.Auth.TOTP.create_challenge(chat_id, action)

        AlexClaw.Gateway.Telegram.send_message(
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
    enabled = Config.get("llm.ollama_enabled")
    host = Config.get("llm.ollama_host") || "http://localhost:11434"

    if enabled not in [true, "true"] do
      %{status: :not_configured, detail: "Ollama disabled"}
    else
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
  end

  defp live_check("lmstudio") do
    enabled = Config.get("llm.lmstudio_enabled")
    host = Config.get("llm.lmstudio_host") || "http://host.docker.internal:1234"

    if enabled not in [true, "true"] do
      %{status: :not_configured, detail: "LM Studio disabled"}
    else
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
  end

  defp live_check("github") do
    token = Config.get("github.token")

    if !token || token == "" do
      %{status: :not_configured, detail: "Token not set"}
    else
      case Req.get("https://api.github.com/user",
             headers: [{"authorization", "Bearer #{token}"}, {"accept", "application/vnd.github+json"}],
             receive_timeout: 5_000) do
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
    enabled = Config.get("web_automator.enabled")
    host = Config.get("web_automator.host") || "http://web-automator:6900"

    if enabled not in [true, "true"] do
      %{status: :not_configured, detail: "Web Automator disabled"}
    else
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
        %{status: :expired, detail: "#{total_stale} stale embeddings (#{stale_mem} memory, #{stale_kb} knowledge) — model: #{model}"}
      end
    end
  end

  defp live_check(_), do: %{status: :error, detail: "Unknown service"}

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
