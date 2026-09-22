defmodule AlexClaw.Gateway.Telegram do
  @moduledoc """
  Telegram Bot API gateway. Long-polls for updates and normalizes them
  into internal %Message{} structs. Sends outbound messages.
  Reads token/chat_id from AlexClaw.Config (runtime-editable).
  """
  @behaviour AlexClaw.Gateway.Behaviour
  use GenServer
  require Logger

  alias AlexClaw.{Config, Message}

  @telegram_api "https://api.telegram.org/bot"

  # --- Behaviour callbacks ---

  @impl AlexClaw.Gateway.Behaviour
  def name, do: :telegram

  @impl AlexClaw.Gateway.Behaviour
  @spec configured?() :: boolean()
  def configured? do
    enabled = Config.get("telegram.enabled")
    token = Config.get("telegram.bot_token")
    enabled in [true, "true"] and token != nil and token != ""
  end

  # --- Client API ---

  @doc "Start the Telegram Gateway GenServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Send a text message to the configured chat."
  @impl AlexClaw.Gateway.Behaviour
  @spec send_message(String.t(), keyword()) :: :ok
  def send_message(text, opts \\ []) do
    GenServer.cast(__MODULE__, {:send, text, opts})
  end

  @doc "Send an HTML-formatted message to the configured chat."
  @impl AlexClaw.Gateway.Behaviour
  @spec send_html(String.t(), keyword()) :: :ok
  def send_html(text, opts \\ []) do
    GenServer.cast(__MODULE__, {:send_html, text, opts})
  end

  @doc "Send a photo to a specific chat."
  @impl AlexClaw.Gateway.Behaviour
  @spec send_photo(term(), binary(), String.t()) :: :ok | {:error, term()}
  def send_photo(chat_id, photo_data, caption) do
    token = get_token()

    if token && token != "" do
      url = "#{@telegram_api}#{token}/sendPhoto"

      case Req.post(url,
             form_multipart: [
               {"chat_id", to_string(chat_id)},
               {"caption", caption},
               {"photo", {photo_data, filename: "qr.png", content_type: "image/png"}}
             ]
           ) do
        {:ok, %{status: 200}} -> :ok
        {:ok, %{status: s, body: b}} -> {:error, {s, b}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :not_configured}
    end
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    state = %{offset: 0}

    # Always schedule the poll loop — it checks config each cycle
    poll_interval = get_poll_interval()
    if poll_interval != :infinity, do: schedule_poll(poll_interval)

    Logger.info("Telegram gateway started", [])
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
    token_for(Config.enabled?("telegram.enabled"), Node.list())
  end

  defp token_for(false, _peers), do: nil

  # Single node: always poll, ignore node assignment
  defp token_for(true, []), do: Config.get("telegram.bot_token")

  # Cluster: must be assigned to this node
  defp token_for(true, _peers), do: token_for_node(Config.get("telegram.node"))

  defp token_for_node(node_name) when node_name in [nil, ""], do: nil

  defp token_for_node(node_name) do
    if node_name == to_string(node()), do: Config.get("telegram.bot_token")
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
        Enum.each(updates, &handle_update/1)
        %{state | offset: next_offset(List.last(updates), state.offset)}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Telegram API error: #{status} - #{inspect(body)}")
        state

      {:error, reason} ->
        Logger.warning("Telegram poll failed: #{inspect(reason)}")
        state
    end
  end

  defp next_offset(nil, offset), do: offset
  defp next_offset(last, _offset), do: last["update_id"] + 1

  defp handle_update(update) do
    message = normalize(update)
    dispatch_message(message, message.text && authorized_chat?(message.chat_id))
  end

  defp dispatch_message(_message, nil), do: :ok

  defp dispatch_message(message, false) do
    Logger.warning("Ignored message from unauthorized chat_id: #{message.chat_id}")
  end

  defp dispatch_message(message, true) do
    Logger.info("Received: #{message.text}", [])
    maybe_save_chat_id(message.chat_id)
    AlexClaw.Dispatcher.dispatch(message)
  end

  defp normalize(update) do
    msg = update["message"] || %{}

    %Message{
      text: msg["text"],
      chat_id: msg["chat"]["id"],
      from: get_in(msg, ["from", "first_name"]),
      timestamp: DateTime.utc_now(),
      raw: update,
      gateway: :telegram
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

      Logger.warning(
        "Auto-saved Telegram chat_id: #{chat_id} — verify this is your chat. Set telegram.chat_id in config to disable auto-detect."
      )
    end
  end

  # Telegram refuses a message over 4096 characters outright, so an overlong
  # one arrived as nothing at all. It is cut, and says so.
  @max_message 4096
  @cut_note "\n… (message truncated)"

  @doc false
  @spec fit(String.t()) :: String.t()
  def fit(text) when is_binary(text) do
    if String.length(text) <= @max_message,
      do: text,
      else: String.slice(text, 0, @max_message - String.length(@cut_note)) <> @cut_note
  end

  defp do_send_html(token, chat_id, text) do
    do_send(token, chat_id, text, "HTML")
  end

  defp do_send_message(token, chat_id, text) do
    do_send(token, chat_id, text, "Markdown")
  end

  defp do_send(token, chat_id, text, parse_mode) do
    url = "#{@telegram_api}#{token}/sendMessage"
    text = fit(text)

    case Req.post(url, json: %{chat_id: chat_id, text: text, parse_mode: parse_mode}) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: 400, body: body}} ->
        Logger.warning("#{parse_mode} parse failed, retrying as plain text: #{inspect(body)}")
        plain_text = if parse_mode == "HTML", do: strip_tags(text), else: text

        case Req.post(url, json: %{chat_id: chat_id, text: plain_text}) do
          {:ok, %{status: 200}} ->
            :ok

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
