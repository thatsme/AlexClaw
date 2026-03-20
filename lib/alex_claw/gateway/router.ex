defmodule AlexClaw.Gateway.Router do
  @moduledoc """
  Routes outbound messages to the correct gateway based on the :gateway opt.
  Falls back to the first configured gateway (Telegram preferred).
  """

  @gateways [AlexClaw.Gateway.Telegram]

  @spec send_message(String.t(), keyword()) :: :ok
  def send_message(text, opts \\ []) do
    resolve_gateway(opts).send_message(text, opts)
  end

  @spec send_html(String.t(), keyword()) :: :ok
  def send_html(text, opts \\ []) do
    resolve_gateway(opts).send_html(text, opts)
  end

  @spec send_photo(term(), binary(), String.t(), keyword()) :: :ok | {:error, term()}
  def send_photo(chat_id, photo_data, caption, opts \\ []) do
    resolve_gateway(opts).send_photo(chat_id, photo_data, caption)
  end

  @doc "Send a message to all active gateways (for system-level notifications)."
  @spec broadcast(String.t(), keyword()) :: :ok
  def broadcast(text, opts \\ []) do
    for gw <- active_gateways(), do: gw.send_message(text, opts)
    :ok
  end

  @doc "List all gateways that are currently configured and active."
  @spec active_gateways() :: [module()]
  def active_gateways do
    Enum.filter(@gateways, & &1.configured?())
  end

  defp resolve_gateway(opts) do
    case Keyword.get(opts, :gateway) do
      :telegram -> AlexClaw.Gateway.Telegram
      nil -> default_gateway()
      _other -> default_gateway()
    end
  end

  defp default_gateway do
    Enum.find(@gateways, AlexClaw.Gateway.Telegram, & &1.configured?())
  end
end
