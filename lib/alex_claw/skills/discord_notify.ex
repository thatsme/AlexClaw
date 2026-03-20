defmodule AlexClaw.Skills.DiscordNotify do
  @moduledoc """
  Skill that sends workflow output to a Discord channel.
  Configurable via step config:
  - "channel_id" — target Discord channel (default: main configured channel)
  """
  @behaviour AlexClaw.Skill

  @impl true
  def description, do: "Sends workflow output to a Discord channel"

  @impl true
  def routes, do: [:on_delivered, :on_error]

  require Logger

  @impl true
  @spec run(map()) :: {:ok, map(), atom()} | {:error, any()}
  def run(args) do
    config = args[:config] || %{}
    input = args[:input]

    message = format_input(input)

    channel_id = config["channel_id"]

    opts =
      if channel_id && channel_id != "" do
        [chat_id: channel_id, gateway: :discord]
      else
        [gateway: :discord]
      end

    if AlexClaw.Gateway.Discord.configured?() do
      # Discord limit is 2000 chars — split into multiple messages if needed
      message
      |> chunk_message(1900)
      |> Enum.each(fn chunk -> AlexClaw.Gateway.Discord.send_message(chunk, opts) end)
      # Pass through the original input so downstream steps still have the data
      {:ok, input, :on_delivered}
    else
      Logger.warning("DiscordNotify: Discord gateway not configured", skill: :discord_notify)
      {:error, :discord_not_configured}
    end
  end

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
