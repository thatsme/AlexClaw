defmodule AlexClaw.Gateway do
  @moduledoc """
  Telegram Bot API gateway. Long-polls for updates and normalizes them
  into internal %Message{} structs. Sends outbound messages.
  Reads token/chat_id from AlexClaw.Config (runtime-editable).
  """
  use GenServer
  require Logger

  alias AlexClaw.{Config, Message}

  @telegram_api "https://api.telegram.org/bot"

  # --- Client API ---

  @doc "Start the Gateway GenServer and register it under its module name."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Send a text message to the configured chat."
  @spec send_message(String.t(), keyword()) :: :ok
  def send_message(text, opts \\ []) do
    GenServer.cast(__MODULE__, {:send, text, opts})
  end

  @doc "Send an HTML-formatted message to the configured chat."
  @spec send_html(String.t(), keyword()) :: :ok
  def send_html(text, opts \\ []) do
    GenServer.cast(__MODULE__, {:send_html, text, opts})
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    state = %{offset: 0}

    token = get_token()
    poll_interval = get_poll_interval()

    if token && token != "" && poll_interval != :infinity do
      schedule_poll(poll_interval)
    end

    Logger.info("Gateway started", [])
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    token = get_token()
    poll_interval = get_poll_interval()

    state =
      if token && token != "" do
        poll_updates(state, token)
      else
        state
      end

    schedule_poll(poll_interval)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:send, text, opts}, state) do
    token = get_token()
    chat_id = Keyword.get(opts, :chat_id) || get_chat_id()

    if token && token != "" && chat_id && chat_id != "" do
      do_send_message(token, chat_id, text)
    else
      preview = String.slice(to_string(text), 0, 80)
      Logger.warning("Cannot send: Telegram token or chat_id not configured — \"#{preview}\"")
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:send_html, text, opts}, state) do
    token = get_token()
    chat_id = Keyword.get(opts, :chat_id) || get_chat_id()

    if token && token != "" && chat_id && chat_id != "" do
      do_send_html(token, chat_id, text)
    else
      preview = String.slice(to_string(text), 0, 80)
      Logger.warning("Cannot send: Telegram token or chat_id not configured — \"#{preview}\"")
    end

    {:noreply, state}
  end

  # --- Config readers (live from DB/ETS) ---

  defp get_token do
    Config.get("telegram.bot_token")
  end

  defp get_chat_id do
    Config.get("telegram.chat_id")
  end

  defp get_poll_interval do
    Config.get("telegram.poll_interval") || 1_000
  end

  # --- Internal ---

  defp schedule_poll(interval) when is_integer(interval) do
    Process.send_after(self(), :poll, interval)
  end

  defp schedule_poll(_), do: :ok

  defp poll_updates(state, token) do
    url = "#{@telegram_api}#{token}/getUpdates"

    case Req.get(url, params: [offset: state.offset, timeout: 30], receive_timeout: 60_000) do
      {:ok, %{status: 200, body: %{"ok" => true, "result" => updates}}} ->
        Enum.each(updates, fn update ->
          message = normalize(update)

          if message.text do
            if authorized_chat?(message.chat_id) do
              Logger.info("Received: #{message.text}", [])
              maybe_save_chat_id(message.chat_id)
              AlexClaw.Dispatcher.dispatch(message)
            else
              Logger.warning("Ignored message from unauthorized chat_id: #{message.chat_id}")
            end
          end
        end)

        new_offset =
          case List.last(updates) do
            nil -> state.offset
            last -> last["update_id"] + 1
          end

        %{state | offset: new_offset}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Telegram API error: #{status} - #{inspect(body)}")
        state

      {:error, reason} ->
        Logger.warning("Telegram poll failed: #{inspect(reason)}")
        state
    end
  end

  defp normalize(update) do
    msg = update["message"] || %{}

    %Message{
      text: msg["text"],
      chat_id: msg["chat"]["id"],
      from: get_in(msg, ["from", "first_name"]),
      timestamp: DateTime.utc_now(),
      raw: update
    }
  end

  defp authorized_chat?(chat_id) do
    configured = get_chat_id()
    # Allow if no chat_id configured yet (first-message auto-detect)
    configured == nil or configured == "" or to_string(chat_id) == to_string(configured)
  end

  defp maybe_save_chat_id(nil), do: :ok
  defp maybe_save_chat_id(chat_id) do
    current = Config.get("telegram.chat_id")
    if current == nil or current == "" do
      Config.set("telegram.chat_id", to_string(chat_id), type: "string", category: "telegram")
      Logger.info("Auto-saved Telegram chat_id: #{chat_id}")
    end
  end

  defp do_send_html(token, chat_id, text) do
    do_send(token, chat_id, text, "HTML")
  end

  defp do_send_message(token, chat_id, text) do
    do_send(token, chat_id, text, "Markdown")
  end

  defp do_send(token, chat_id, text, parse_mode) do
    url = "#{@telegram_api}#{token}/sendMessage"

    case Req.post(url, json: %{chat_id: chat_id, text: text, parse_mode: parse_mode}) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: 400, body: body}} ->
        Logger.warning("#{parse_mode} parse failed, retrying as plain text: #{inspect(body)}")
        plain_text = if parse_mode == "HTML", do: strip_tags(text), else: text

        case Req.post(url, json: %{chat_id: chat_id, text: plain_text}) do
          {:ok, %{status: 200}} -> :ok
          {:ok, %{status: s, body: b}} ->
            Logger.warning("Plain text send also failed: #{s} - #{inspect(b)}")
            {:error, b}
          {:error, reason} ->
            Logger.warning("Plain text send error: #{inspect(reason)}")
            {:error, reason}
        end

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Send failed: #{status} - #{inspect(body)}")
        {:error, body}

      {:error, reason} ->
        Logger.warning("Send error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp strip_tags(text), do: Regex.replace(~r/<[^>]+>/, text, "")
end
