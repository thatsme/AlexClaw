defmodule AlexClaw.Gateway.Credentials do
  @moduledoc """
  Where a gateway's token and destination come from.

  The database wins whenever it holds a value: these are settings, and an
  operator who changed one meant it. A blank setting falls back to the
  environment, which is how an instance is reachable before anyone has been
  able to configure it.

  That fallback is load-bearing rather than convenient. The admin control plane
  is read-only until 2FA is configured, and configuring 2FA means answering a
  code on a gateway — so an instance with no reachable gateway cannot be
  configured at all, including to fix the gateway. The environment is the only
  way in, and it is the only way in by design: there is no variable that
  disables the gate.

  A setting cleared deliberately therefore comes back if the variable is still
  set. Under a read-only control plane, resurrecting a notification target is
  the safer failure.
  """

  alias AlexClaw.Config

  @doc "Telegram bot token: the setting, or `TELEGRAM_BOT_TOKEN`."
  @spec telegram_token() :: String.t() | nil
  def telegram_token, do: resolve("telegram.bot_token", "TELEGRAM_BOT_TOKEN")

  @doc "Telegram chat to notify: the setting, or `TELEGRAM_CHAT_ID`."
  @spec telegram_chat_id() :: String.t() | nil
  def telegram_chat_id, do: resolve("telegram.chat_id", "TELEGRAM_CHAT_ID")

  @doc "Discord bot token: the setting, or `DISCORD_BOT_TOKEN`."
  @spec discord_token() :: String.t() | nil
  def discord_token, do: resolve("discord.bot_token", "DISCORD_BOT_TOKEN")

  @doc "Discord channel to notify: the setting, or `DISCORD_CHANNEL_ID`."
  @spec discord_channel_id() :: String.t() | nil
  def discord_channel_id, do: resolve("discord.channel_id", "DISCORD_CHANNEL_ID")

  @doc """
  Every destination a second-factor prompt can be sent to.

  Empty means no second factor can be asked for, which under a read-only
  control plane means nothing can be changed until one is configured.
  """
  @spec notify_targets() :: [String.t()]
  def notify_targets do
    [telegram_chat_id(), discord_channel_id()]
    |> Enum.reject(&blank?/1)
  end

  @doc "Whether any gateway could receive a prompt right now."
  @spec reachable?() :: boolean()
  def reachable?, do: notify_targets() != []

  defp resolve(key, env_var), do: fallback(Config.get(key), env_var)

  # Whitespace is not a value. A setting someone cleared by selecting the field
  # and pressing space reads as configured to `!= ""` and as nothing to a human.
  defp fallback(value, env_var) when is_binary(value) do
    present(String.trim(value), value, env_var)
  end

  defp fallback(_blank, env_var), do: System.get_env(env_var)

  defp present("", _value, env_var), do: System.get_env(env_var)
  defp present(_trimmed, value, _env_var), do: value

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value), do: String.trim(value) == ""
end
