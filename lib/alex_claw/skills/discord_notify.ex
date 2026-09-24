defmodule AlexClaw.Skills.DiscordNotify do
  @moduledoc """
  Skill that sends workflow output to a Discord channel.
  Configurable via step config:
  - "channel_id" — target Discord channel (default: main configured channel)
  """
  @behaviour AlexClaw.Skill

  alias AlexClaw.Gateway.Discord

  @impl true
  @spec description() :: String.t()
  def description, do: "Sends workflow output to a Discord channel"

  @impl true
  @spec routes() :: [atom()]
  def routes, do: [:on_delivered, :on_error]

  @impl true
  @spec step_fields() :: [atom()]
  def step_fields, do: [:config]

  @impl true
  @spec config_hint() :: String.t()
  def config_hint, do: ~s|{"channel_id": "Discord channel ID (optional, default: main channel)"}|

  @impl true
  @spec config_scaffold() :: map()
  def config_scaffold, do: %{"channel_id" => ""}

  @impl true
  @spec config_schema() :: AlexClaw.Skill.config_schema()
  def config_schema, do: %{"channel_id" => %{type: :string, required: false}}

  @impl true
  @spec available?() :: boolean()
  def available?, do: Discord.configured?()

  @impl true
  @spec config_help() :: String.t()
  def config_help,
    do: "channel_id: target Discord channel. Leave empty to send to the default channel."

  require Logger

  @impl true
  @spec run(map()) :: {:ok, map(), atom()} | {:error, any()}
  def run(args) do
    config = args[:config] || %{}
    input = args[:input]

    message = format_input(input)

    channel_id = blank_to_nil(config["channel_id"]) || AlexClaw.Config.get("discord.channel_id")

    send_to(Discord.configured?(), channel_id, message, input)
  end

  defp send_to(false, _channel_id, _message, _input) do
    Logger.warning("DiscordNotify: Discord gateway not configured", skill: :discord_notify)
    {:error, :discord_not_configured}
  end

  # Nowhere to send is not a delivery.
  defp send_to(true, channel_id, _message, _input) when channel_id in [nil, ""],
    do: {:error, :no_channel_id}

  # Delivered only when Discord accepted every chunk; the first refusal stops
  # the rest and is the step's error.
  defp send_to(true, channel_id, message, input) do
    # Discord limit is 2000 chars — split into multiple messages if needed
    message
    |> chunk_message(1900)
    |> Enum.reduce_while(:ok, fn chunk, :ok ->
      chunk_sent(Discord.send_message(chunk, chat_id: channel_id, gateway: :discord))
    end)
    |> delivered(input)
  end

  defp chunk_sent(:ok), do: {:cont, :ok}
  defp chunk_sent(error), do: {:halt, error}

  # Pass through the original input so downstream steps still have the data
  defp delivered(:ok, input), do: {:ok, input, :on_delivered}
  defp delivered({:error, reason}, _input), do: {:error, reason}

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp chunk_message(text, max) do
    if String.length(text) <= max do
      [text]
    else
      text
      |> String.graphemes()
      |> Enum.chunk_every(max)
      |> Enum.map(&Enum.join/1)
    end
  end

  defp format_input(nil), do: "Workflow completed (no output)"
  defp format_input(text) when is_binary(text), do: text
  defp format_input(%{"output" => text}) when is_binary(text), do: text
  defp format_input(other), do: inspect(other)
end
