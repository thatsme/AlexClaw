defmodule AlexClaw.Gateway.DiscordStarter do
  @moduledoc """
  Starts the Discord gateway after Config.Loader has populated ETS.
  Resolves discord.bot_token (a secret setting, kept in OpenBao) once, reads
  discord.enabled, configures Nostrum at runtime, and starts it if enabled.
  No .env required — configure entirely from Admin > Config.

  The token is resolved again when it is rotated (`AlexClaw.Secrets` announces
  it) and handed to Nostrum, which uses it from its next connection. Nostrum
  keeps its copy in its application environment: that copy is the one place
  outside this process the token lives.
  """
  use GenServer
  require Logger

  alias AlexClaw.Config.SecretSettings

  @key "discord.bot_token"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(AlexClaw.PubSub, AlexClaw.Secrets.topic())
    # Small delay to ensure Config.Loader has finished seeding
    Process.send_after(self(), :start_discord, 1_000)
    {:ok, %{started: false}}
  end

  @impl true
  def handle_info(:start_discord, state) do
    token = bot_token()

    start_discord(state, token, startable?(token))
  end

  def handle_info({:secret_rotated, name}, %{started: true} = state) do
    if name == SecretSettings.secret_name(@key), do: rotated(bot_token())
    {:noreply, state}
  end

  def handle_info({:secret_rotated, _name}, state), do: {:noreply, state}

  defp rotated(nil), do: Logger.warning("Discord bot token removed; Nostrum keeps the old one")
  defp rotated(token), do: Application.put_env(:nostrum, :token, token)

  defp bot_token, do: AlexClaw.Config.secret_value(@key, for: "host:discord.com")

  defp startable?(token) when not is_binary(token) or token == "", do: false

  defp startable?(_token) do
    AlexClaw.Config.enabled?("discord.enabled") and assigned_to_this_node?()
  end

  # Single node: always start. Cluster: check node assignment.
  defp assigned_to_this_node? do
    AlexClaw.Cluster.list_nodes()
    |> length()
    |> node_assignment()
  end

  defp node_assignment(cluster_size) when cluster_size <= 1, do: true
  defp node_assignment(_cluster_size), do: this_node?(AlexClaw.Config.get("discord.node"))

  defp this_node?(node_name) when node_name in [nil, ""], do: false
  defp this_node?(node_name), do: to_string(node()) == node_name

  defp start_discord(state, _token, false) do
    Logger.info("Discord gateway disabled (not configured)")
    {:noreply, state}
  end

  defp start_discord(state, token, true) do
    Application.put_env(:nostrum, :token, token)
    Application.put_env(:nostrum, :gateway_intents, [:guilds, :guild_messages, :message_content])

    case Application.ensure_all_started(:nostrum) do
      {:ok, _} ->
        start_consumer(state)

      {:error, reason} ->
        Logger.warning("Discord gateway disabled: Nostrum failed to start — #{inspect(reason)}")
        {:noreply, state}
    end
  end

  # Start the Discord consumer under AlexClaw's supervisor
  defp start_consumer(state) do
    case Supervisor.start_child(AlexClaw.Supervisor, AlexClaw.Gateway.Discord) do
      {:ok, _pid} ->
        Logger.info("Discord gateway started")
        {:noreply, %{state | started: true}}

      {:error, reason} ->
        Logger.warning("Discord consumer failed to start: #{inspect(reason)}")
        {:noreply, state}
    end
  end
end
