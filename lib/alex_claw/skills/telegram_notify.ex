defmodule AlexClaw.Skills.TelegramNotify do
  @moduledoc """
  Skill that sends the workflow output to Telegram.
  Configurable via step config:
  - "chat_id" — override target chat (default: main configured chat)
  - "bot_token" — override bot token (default: main configured token)
  - "link_preview" — `false` turns off the preview card Telegram adds for a link

  The message is sent as HTML, converted from the Markdown the previous step
  produced (`to_html/1`).
  """
  @behaviour AlexClaw.Skill
  @impl true
  @spec description() :: String.t()
  def description, do: "Sends workflow output to Telegram chat"

  @impl true
  @spec routes() :: [atom()]
  def routes, do: [:on_delivered, :on_error]

  @impl true
  @spec step_fields() :: [atom()]
  def step_fields, do: [:config]

  @impl true
  @spec secret_config_keys() :: [String.t()]
  def secret_config_keys, do: ["bot_token"]

  @impl true
  @spec config_hint() :: String.t()
  def config_hint,
    do: ~s|{"chat_id": "optional", "bot_token": "optional", "link_preview": false}|

  @impl true
  @spec config_scaffold() :: map()
  def config_scaffold, do: %{"chat_id" => "", "bot_token" => ""}

  @impl true
  @spec config_help() :: String.t()
  def config_help,
    do:
      "Optional overrides. Leave empty to use default bot/chat. link_preview: false turns off the link preview card."

  require Logger

  @telegram_api "https://api.telegram.org/bot"

  @impl true
  @spec run(map()) :: {:ok, map()} | {:error, any()}
  def run(args) do
    config = args[:config] || %{}
    input = args[:input]

    message = format_input(input)

    # Truncate to Telegram's 4096 char limit
    message =
      if String.length(message) > 4000 do
        String.slice(message, 0, 4000) <> "\n... (truncated)"
      else
        message
      end

    bot_token = blank_to_nil(config["bot_token"])
    chat_id = blank_to_nil(config["chat_id"])

    html_message = to_html(message)
    options = send_options(config)

    if bot_token && bot_token != "" do
      send_direct(bot_token, chat_id, html_message, options, input)
    else
      chat_id = chat_id || AlexClaw.Config.get("telegram.chat_id")
      send_default(chat_id, html_message, options, input)
    end
  end

  # Nowhere to send is not a delivery.
  defp send_default(chat_id, _text, _options, _input) when chat_id in [nil, ""],
    do: {:error, :no_chat_id}

  defp send_default(chat_id, text, options, input) do
    AlexClaw.Gateway.send_html(text, chat_id: chat_id, send_options: options)
    # Pass through original input so downstream steps still have the data
    {:ok, input, :on_delivered}
  end

  defp send_direct(_token, chat_id, _text, _options, _input) when chat_id in [nil, ""] do
    {:error, :no_chat_id}
  end

  defp send_direct(token, chat_id, text, options, input) do
    url = "#{@telegram_api}#{token}/sendMessage"
    request = Map.merge(%{chat_id: chat_id, text: text, parse_mode: "HTML"}, options)

    case Req.post(url, json: request) do
      {:ok, %{status: 200}} ->
        Logger.info("TelegramNotify sent to chat #{chat_id} via custom bot",
          skill: :telegram_notify
        )

        {:ok, input, :on_delivered}

      {:ok, %{status: 400, body: body}} ->
        Logger.warning("TelegramNotify markdown failed, retrying plain: #{inspect(body)}",
          skill: :telegram_notify
        )

        send_plain(url, Map.delete(request, :parse_mode), input)

      {:ok, %{status: status, body: body}} ->
        Logger.warning("TelegramNotify failed: #{status}", skill: :telegram_notify)
        {:error, {:telegram, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_plain(url, request, input) do
    case Req.post(url, json: request) do
      {:ok, %{status: 200}} -> {:ok, input, :on_delivered}
      {:ok, %{status: s, body: b}} -> {:error, {:telegram, s, b}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp format_input(nil), do: "Workflow completed (no output)"
  defp format_input(text) when is_binary(text), do: text
  defp format_input(%{"output" => text}) when is_binary(text), do: text
  defp format_input(other), do: inspect(other)

  @doc "Same as `to_html/1`."
  @spec format_for_telegram(String.t()) :: String.t()
  def format_for_telegram(text), do: to_html(text)

  @doc """
  Converts LLM markdown output to Telegram-compatible HTML: headers, bold,
  italic, inline code, bullet lists, and `[text](url)` links. Everything else
  is escaped. Only http and https URLs become links; the link text is escaped
  and the URL is escaped for the attribute, so neither can add markup.
  """
  @spec to_html(String.t()) :: String.t()
  def to_html(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &convert_line/1)
  end

  @doc """
  Extra sendMessage fields from the step config: `"link_preview": false`
  turns the link preview card off.
  """
  @spec send_options(map()) :: map()
  def send_options(%{"link_preview" => false}), do: %{link_preview_options: %{is_disabled: true}}
  def send_options(_config), do: %{}

  defp convert_line("#### " <> rest), do: "<b>#{escape_html(rest)}</b>"
  defp convert_line("### " <> rest), do: "<b>#{escape_html(rest)}</b>"
  defp convert_line("## " <> rest), do: "<b>#{escape_html(rest)}</b>"
  defp convert_line("# " <> rest), do: "<b>#{escape_html(rest)}</b>"
  defp convert_line("- " <> rest), do: "• #{convert_inline(rest)}"
  defp convert_line("* " <> rest), do: "• #{convert_inline(rest)}"
  defp convert_line(line), do: convert_inline(line)

  # Links are split out first, so the text around them is escaped and
  # formatted as before and the link itself is built from escaped parts.
  defp convert_inline(text) do
    ~r/\[[^\]]+\]\(https?:\/\/[^)\s]+\)/i
    |> Regex.split(text, include_captures: true)
    |> Enum.map_join(&convert_part/1)
  end

  defp convert_part(part) do
    ~r/^\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)$/i
    |> Regex.run(part, capture: :all_but_first)
    |> link_or_text(part)
  end

  defp link_or_text([text, url], _part),
    do: ~s(<a href="#{escape_attribute(url)}">#{escape_html(text)}</a>)

  defp link_or_text(nil, part) do
    part
    |> escape_html()
    |> convert_bold()
    |> convert_italic()
    |> convert_inline_code()
  end

  defp escape_attribute(url), do: url |> escape_html() |> String.replace("\"", "&quot;")

  defp escape_html(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp convert_bold(text) do
    Regex.replace(~r/\*\*(.+?)\*\*/, text, "<b>\\1</b>")
  end

  defp convert_italic(text) do
    Regex.replace(~r/(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)/, text, "<i>\\1</i>")
  end

  defp convert_inline_code(text) do
    Regex.replace(~r/`(.+?)`/, text, "<code>\\1</code>")
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(val), do: val
end
