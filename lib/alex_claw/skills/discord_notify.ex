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

    # Discord's message limit is 2000 chars
    message =
      if String.length(message) > 1900 do
        String.slice(message, 0, 1900) <> "\n... (truncated)"
      else
        message
      end

    channel_id = config["channel_id"]

    opts =
      if channel_id && channel_id != "" do
        [chat_id: channel_id, gateway: :discord]
      else
        [gateway: :discord]
      end

    if AlexClaw.Gateway.Discord.configured?() do
      AlexClaw.Gateway.Discord.send_message(message, opts)
      {:ok, %{delivered: true, channel_id: channel_id || "default"}, :on_delivered}
    else
      Logger.warning("DiscordNotify: Discord gateway not configured", skill: :discord_notify)
      {:error, :discord_not_configured}
    end
  end

  defp format_input(nil), do: "Workflow completed (no output)"
  defp format_input(text) when is_binary(text), do: text
  defp format_input(%{"output" => text}) when is_binary(text), do: text
  defp format_input(other), do: inspect(other)
end
