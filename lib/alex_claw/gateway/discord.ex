defmodule AlexClaw.Gateway.Discord do
  @moduledoc """
  Discord gateway. Uses Nostrum for the Discord Gateway WebSocket (receiving)
  and REST API (sending). Normalizes Discord events into %Message{} structs
  and routes them through the Dispatcher.

  Gracefully no-ops if Discord is not configured (no token or disabled).
  """
  @behaviour AlexClaw.Gateway.Behaviour

  use Nostrum.Consumer
  require Logger

  alias AlexClaw.{Config, Message}

  # --- Behaviour callbacks ---

  @impl AlexClaw.Gateway.Behaviour
  def name, do: :discord

  @impl AlexClaw.Gateway.Behaviour
  @spec configured?() :: boolean()
  def configured? do
    enabled = Config.get("discord.enabled")
    token = Config.get("discord.bot_token")
    (enabled == true or enabled == "true") and token != nil and token != ""
  end

  @impl AlexClaw.Gateway.Behaviour
  @spec send_message(String.t(), keyword()) :: :ok
  @discord_max_length 2000

  def send_message(text, opts \\ []) do
    channel_id = Keyword.get(opts, :chat_id) || get_channel_id()

    if channel_id && channel_id != "" do
      channel_id = to_integer(channel_id)

      text
      |> chunk_message(@discord_max_length)
      |> Enum.each(fn chunk ->
        case Nostrum.Api.Message.create(channel_id, content: chunk) do
          {:ok, _msg} -> :ok
          {:error, reason} ->
            Logger.warning("Discord send failed: #{inspect(reason)}")
            :ok
        end
      end)

      :ok
    else
      Logger.warning("Cannot send to Discord: channel_id not configured")
      :ok
    end
  end

  @impl AlexClaw.Gateway.Behaviour
  @spec send_html(String.t(), keyword()) :: :ok
  def send_html(text, opts \\ []) do
    # Discord uses Markdown, not HTML — strip tags and send as plain text
    plain = Regex.replace(~r/<[^>]+>/, text, "")
    send_message(plain, opts)
  end

  @impl AlexClaw.Gateway.Behaviour
  @spec send_photo(term(), binary(), String.t()) :: :ok | {:error, term()}
  def send_photo(channel_id, photo_data, caption) do
    channel_id = to_integer(channel_id || get_channel_id())

    case Nostrum.Api.Message.create(channel_id,
           content: caption,
           files: [%{name: "image.png", body: photo_data}]
         ) do
      {:ok, _msg} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # --- Nostrum Consumer callbacks ---

  @impl Nostrum.Consumer
  def handle_event({:MESSAGE_CREATE, msg, _ws_state}) do
    # Ignore messages from bots (including ourselves)
    if msg.author.bot do
      :noop
    else
      if authorized_channel?(msg.channel_id) do
        message = normalize(msg)
        Logger.info("Discord received: #{message.text}")
        maybe_save_channel_id(msg.channel_id)
        AlexClaw.Dispatcher.dispatch(message)
      else
        Logger.debug("Discord: ignored message from unauthorized channel #{msg.channel_id}")
      end
    end
  end

  @spec handle_event(term()) :: :noop
  def handle_event(_event), do: :noop

  # --- Internal ---

  defp chunk_message(text, max_length) when byte_size(text) <= max_length, do: [text]

  defp chunk_message(text, max_length) do
    text
    |> String.split("\n")
    |> Enum.reduce([""], fn line, [current | rest] ->
      candidate = if current == "", do: line, else: current <> "\n" <> line

      if byte_size(candidate) <= max_length do
        [candidate | rest]
      else
        [line, current | rest]
      end
    end)
    |> Enum.reverse()
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize(msg) do
    %Message{
      text: msg.content,
      chat_id: msg.channel_id,
      from: msg.author.username,
      timestamp: DateTime.utc_now(),
      raw: %{discord_message: msg},
      gateway: :discord
    }
  end

  defp authorized_channel?(channel_id) do
    configured = get_channel_id()
    # Allow if no channel_id configured yet (first-message auto-detect)
    configured == nil or configured == "" or to_string(channel_id) == to_string(configured)
  end

  defp maybe_save_channel_id(channel_id) do
    current = Config.get("discord.channel_id")

    if current == nil or current == "" do
      Config.set("discord.channel_id", to_string(channel_id),
        type: "string",
        category: "discord"
      )

      Logger.warning("Auto-saved Discord channel_id: #{channel_id} — verify this is your channel. Set discord.channel_id in config to disable auto-detect.")
    end
  end

  defp get_channel_id do
    Config.get("discord.channel_id")
  end

  defp to_integer(val) when is_integer(val), do: val

  defp to_integer(val) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} -> int
      :error -> val
    end
  end

  defp to_integer(val), do: val
end
