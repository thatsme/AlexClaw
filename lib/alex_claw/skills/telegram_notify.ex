defmodule AlexClaw.Skills.TelegramNotify do
  @moduledoc """
  Skill that sends the workflow output to Telegram.
  Configurable via step config:
  - "chat_id" — override target chat (default: main configured chat)
  - "bot_token" — override bot token (default: main configured token)
  - "parse_mode" — "Markdown" (default) or "HTML"
  """
  @behaviour AlexClaw.Skill
  @impl true
  def description, do: "Sends workflow output to Telegram chat"

  @impl true
  def routes, do: [:on_delivered, :on_error]
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

    html_message = format_for_telegram(message)

    if bot_token && bot_token != "" do
      send_direct(bot_token, chat_id, html_message, "HTML")
    else
      opts = if chat_id, do: [chat_id: chat_id], else: []
      AlexClaw.Gateway.send_html(html_message, opts)
      {:ok, %{delivered: true, chat_id: chat_id || "default"}, :on_delivered}
    end
  end

  defp send_direct(_token, chat_id, _text, _parse_mode) when chat_id in [nil, ""] do
    {:error, :no_chat_id}
  end

  defp send_direct(token, chat_id, text, parse_mode) do
    url = "#{@telegram_api}#{token}/sendMessage"

    case Req.post(url, json: %{chat_id: chat_id, text: text, parse_mode: parse_mode}) do
      {:ok, %{status: 200}} ->
        Logger.info("TelegramNotify sent to chat #{chat_id} via custom bot", skill: :telegram_notify)
        {:ok, %{delivered: true, chat_id: chat_id, custom_bot: true}, :on_delivered}

      {:ok, %{status: 400, body: body}} ->
        Logger.warning("TelegramNotify markdown failed, retrying plain: #{inspect(body)}", skill: :telegram_notify)
        case Req.post(url, json: %{chat_id: chat_id, text: text}) do
          {:ok, %{status: 200}} ->
            {:ok, %{delivered: true, chat_id: chat_id, custom_bot: true, plain_fallback: true}, :on_delivered}
          {:ok, %{status: s, body: b}} ->
            {:error, {:telegram, s, b}}
          {:error, reason} ->
            {:error, reason}
        end

      {:ok, %{status: status, body: body}} ->
        Logger.warning("TelegramNotify failed: #{status}", skill: :telegram_notify)
        {:error, {:telegram, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp format_input(nil), do: "Workflow completed (no output)"
  defp format_input(text) when is_binary(text), do: text
  defp format_input(%{"output" => text}) when is_binary(text), do: text
  defp format_input(other), do: inspect(other)

  @doc """
  Converts LLM markdown output to Telegram-compatible HTML.
  Handles headers, bold, italic, code blocks, and bullet lists.
  """
  def format_for_telegram(text) do
    text
    |> String.split("\n")
    |> Enum.map(&convert_line/1)
    |> Enum.join("\n")
  end

  defp convert_line("#### " <> rest), do: "<b>#{escape_html(rest)}</b>"
  defp convert_line("### " <> rest), do: "<b>#{escape_html(rest)}</b>"
  defp convert_line("## " <> rest), do: "<b>#{escape_html(rest)}</b>"
  defp convert_line("# " <> rest), do: "<b>#{escape_html(rest)}</b>"
  defp convert_line("- " <> rest), do: "• #{convert_inline(rest)}"
  defp convert_line("* " <> rest), do: "• #{convert_inline(rest)}"
  defp convert_line(line), do: convert_inline(line)

  defp convert_inline(text) do
    text
    |> escape_html()
    |> convert_bold()
    |> convert_italic()
    |> convert_inline_code()
  end

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
