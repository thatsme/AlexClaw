defmodule AlexClaw.Gateway.Telegram do
  @moduledoc """
  Telegram Bot API gateway. Long-polls for updates and normalizes them
  into internal %Message{} structs. Sends outbound messages.
  Reads token/chat_id from AlexClaw.Config (runtime-editable).
  """
  @behaviour AlexClaw.Gateway.Behaviour
  use GenServer
  require Logger

  @token_key "telegram.bot_token"

  alias AlexClaw.{Config, Message}
  alias AlexClaw.Gateway.Telegram.Token
  alias AlexClaw.Net.Credentials
  alias AlexClaw.Secrets.Mask

  # --- Behaviour callbacks ---

  @impl AlexClaw.Gateway.Behaviour
  def name, do: :telegram

  @impl AlexClaw.Gateway.Behaviour
  @spec configured?() :: boolean()
  def configured? do
    Config.enabled?("telegram.enabled") and Config.secret_set_at(@token_key) != nil
  end

  @doc """
  The bot token, or nil when none is set. Resolved once and held by
  `AlexClaw.Gateway.Telegram.Token`, which resolves again only on a rotation or
  when Telegram refuses it.
  """
  @spec bot_token() :: String.t() | nil
  def bot_token, do: Token.get()

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
    GenServer.cast(__MODULE__, {:send, Mask.mask(text), opts})
  end

  @doc "Send an HTML-formatted message to the configured chat."
  @impl AlexClaw.Gateway.Behaviour
  @spec send_html(String.t(), keyword()) :: :ok
  def send_html(text, opts \\ []) do
    GenServer.cast(__MODULE__, {:send_html, Mask.mask(text), opts})
  end

  @doc """
  Send `text` (HTML) to `chat_id` in the calling process and return Telegram's
  answer: `:ok`, or `{:error, reason}`. When Telegram refuses the HTML, the
  text is sent again as plain text. Options: `:send_options`, a map of extra
  sendMessage fields; `:bot_token`, a bot other than the configured one.
  `send_html/2` stays a cast, for notices that do not need the answer.
  """
  @spec deliver(String.t() | integer(), String.t(), keyword()) :: :ok | {:error, term()}
  def deliver(chat_id, text, opts \\ []) do
    opts
    |> Keyword.get_lazy(:bot_token, &get_token/0)
    |> deliver_with(chat_id, text, Keyword.get(opts, :send_options, %{}))
  end

  defp deliver_with(token, _chat_id, _text, _send_options) when token in [nil, ""],
    do: {:error, :telegram_not_configured}

  defp deliver_with(token, chat_id, text, send_options),
    do: do_send(token, chat_id, text, "HTML", send_options)

  @doc """
  The URL of a Bot API `method` for `token`. The base is the
  `:telegram_api_base` setting (default `https://api.telegram.org`).
  """
  @spec api_url(String.t(), String.t()) :: String.t()
  def api_url(token, method) do
    base = Application.get_env(:alex_claw, :telegram_api_base, "https://api.telegram.org")
    "#{base}/bot#{token}/#{method}"
  end

  @doc "Send a photo to a specific chat."
  @impl AlexClaw.Gateway.Behaviour
  @spec send_photo(term(), binary(), String.t()) :: :ok | {:error, term()}
  def send_photo(chat_id, photo_data, caption) do
    token = get_token()

    if token && token != "" do
      url = api_url(token, "sendPhoto")

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
      do_send_html(token, chat_id, text, Keyword.get(opts, :send_options, %{}))
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
  defp token_for(true, []), do: bot_token()

  # Cluster: must be assigned to this node
  defp token_for(true, _peers), do: token_for_node(Config.get("telegram.node"))

  defp token_for_node(node_name) when node_name in [nil, ""], do: nil

  defp token_for_node(node_name) do
    if node_name == to_string(node()), do: bot_token()
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
    url = api_url(token, "getUpdates")

    case Req.get(url, params: [offset: state.offset, timeout: 30], receive_timeout: 60_000) do
      {:ok, %{status: 200, body: %{"ok" => true, "result" => updates}}} ->
        %{state | offset: process_updates(updates, state.offset, &AlexClaw.Dispatcher.dispatch/1)}

      {:ok, %{status: 401, body: body}} ->
        Token.invalidate()
        Logger.warning("Telegram API error: 401 - #{inspect(body)}")
        state

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Telegram API error: #{status} - #{inspect(body)}")
        state

      {:error, reason} ->
        Logger.warning("Telegram poll failed: #{inspect(reason)}")
        state
    end
  end

  @doc """
  Handle one `getUpdates` batch and return the offset past it.

  Each update is handled on its own, with `dispatch`. An exception, exit or
  throw while handling one is logged and the batch goes on: the offset always
  moves past every update, so a message that crashes its handler is
  acknowledged rather than delivered again. Delivery is at most once.
  """
  @spec process_updates([map()], non_neg_integer(), (Message.t() -> term())) :: non_neg_integer()
  def process_updates(updates, offset, dispatch) do
    Enum.each(updates, &handle_update(&1, dispatch))
    next_offset(List.last(updates), offset)
  end

  defp next_offset(nil, offset), do: offset
  defp next_offset(last, _offset), do: last["update_id"] + 1

  # The boundary between Telegram and everything a message can reach: whatever
  # one update does, the next is still handled and the offset still moves.
  defp handle_update(update, dispatch) do
    message = normalize(update)
    dispatch_message(message, message.text && authorized_chat?(message.chat_id), dispatch)
  catch
    kind, reason ->
      Logger.error(
        "Telegram update #{update["update_id"]} failed and was dropped: " <>
          Exception.format(kind, reason, __STACKTRACE__)
      )
  end

  defp dispatch_message(_message, nil, _dispatch), do: :ok

  defp dispatch_message(message, false, _dispatch) do
    Logger.warning("Ignored message from unauthorized chat_id: #{message.chat_id}")
  end

  defp dispatch_message(message, true, dispatch) do
    Logger.info("Received: #{message.text}", [])
    dispatch.(message)
  end

  defp normalize(update) do
    msg = update["message"] || %{}

    %Message{
      text: msg["text"],
      chat_id: msg["chat"]["id"],
      user_id: get_in(msg, ["from", "id"]),
      from: get_in(msg, ["from", "first_name"]),
      timestamp: DateTime.utc_now(),
      raw: update,
      gateway: :telegram
    }
  end

  # Only the owner chat, set in the admin UI (:set_gateway_owner), is
  # answered. With none set nothing is, and no message makes its chat the
  # owner.
  defp authorized_chat?(chat_id), do: owner?(get_chat_id(), chat_id)

  defp owner?(configured, _chat_id) when configured in [nil, ""], do: false
  defp owner?(configured, chat_id), do: to_string(chat_id) == to_string(configured)

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

  # `send_options` are extra sendMessage fields, e.g. link_preview_options.
  defp do_send_html(token, chat_id, text, send_options) do
    do_send(token, chat_id, text, "HTML", send_options)
  end

  defp do_send_message(token, chat_id, text) do
    do_send(token, chat_id, text, "Markdown", %{})
  end

  defp do_send(token, chat_id, text, parse_mode, send_options) do
    url = api_url(token, "sendMessage")
    text = fit(text)
    request = Map.merge(%{chat_id: chat_id, text: text, parse_mode: parse_mode}, send_options)

    case post_json(url, request) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: 400, body: body}} ->
        Logger.warning("#{parse_mode} parse failed, retrying as plain text: #{inspect(body)}")
        plain_text = if parse_mode == "HTML", do: strip_tags(text), else: text
        send_plain(url, Map.merge(%{chat_id: chat_id, text: plain_text}, send_options))

      {:ok, %{status: 401, body: body}} ->
        invalidate_if_held(token)
        Logger.warning("Send failed: 401 - #{inspect(body)}")
        {:error, {:telegram, 401, body}}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Send failed: #{status} - #{inspect(body)}")
        {:error, {:telegram, status, body}}

      {:error, reason} ->
        Logger.warning("Send error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # A step's own bot token reaches it as a placeholder; it is filled at send,
  # only for the Bot API host it is bound to (AlexClaw.Net.Credentials).
  defp post_json(url, request) do
    [method: :post, url: url, json: request]
    |> Req.new()
    |> Credentials.attach()
    |> Req.request()
  end

  # A 401 says the token that was used is not valid. When that is the held
  # token, it is resolved again on next use; a step's own token says nothing
  # about the held one.
  defp invalidate_if_held(token), do: invalidated(token == Token.get())

  defp invalidated(true), do: Token.invalidate()
  defp invalidated(false), do: :ok

  defp send_plain(url, request) do
    case post_json(url, request) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: s, body: b}} ->
        Logger.warning("Plain text send also failed: #{s} - #{inspect(b)}")
        {:error, {:telegram, s, b}}

      {:error, reason} ->
        Logger.warning("Plain text send error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp strip_tags(text), do: Regex.replace(~r/<[^>]+>/, text, "")
end
