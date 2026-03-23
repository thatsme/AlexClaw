defmodule AlexClaw.Gateway.DiscordStarter do
  @moduledoc """
  Starts the Discord gateway after Config.Loader has populated ETS.
  Reads discord.bot_token and discord.enabled from DB config,
  configures Nostrum at runtime, and starts it if enabled.
  No .env required — configure entirely from Admin > Config.
  """
  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Small delay to ensure Config.Loader has finished seeding
    Process.send_after(self(), :start_discord, 1_000)
    {:ok, %{started: false}}
  end

  @impl true
  def handle_info(:start_discord, state) do
    token = AlexClaw.Config.get("discord.bot_token")
    enabled = AlexClaw.Config.get("discord.enabled")

    # Single node: always start. Cluster: check node assignment.
    cluster_size = length(AlexClaw.Cluster.list_nodes())

    on_this_node =
      if cluster_size <= 1 do
        true
      else
        case AlexClaw.Config.get("discord.node") do
          val when val in [nil, ""] -> false
          node_name -> to_string(node()) == node_name
        end
      end

    if on_this_node and (enabled == true or enabled == "true") and is_binary(token) and token != "" do
      Application.put_env(:nostrum, :token, token)
      Application.put_env(:nostrum, :gateway_intents, [:guilds, :guild_messages, :message_content])

      case Application.ensure_all_started(:nostrum) do
        {:ok, _} ->
          # Start the Discord consumer under AlexClaw's supervisor
          case Supervisor.start_child(AlexClaw.Supervisor, AlexClaw.Gateway.Discord) do
            {:ok, _pid} ->
              Logger.info("Discord gateway started")
              {:noreply, %{state | started: true}}

            {:error, reason} ->
              Logger.warning("Discord consumer failed to start: #{inspect(reason)}")
              {:noreply, state}
          end

        {:error, reason} ->
          Logger.warning("Discord gateway disabled: Nostrum failed to start — #{inspect(reason)}")
          {:noreply, state}
      end
    else
      Logger.info("Discord gateway disabled (not configured)")
      {:noreply, state}
    end
  end
end
