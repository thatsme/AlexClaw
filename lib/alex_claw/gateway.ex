defmodule AlexClaw.Gateway do
  @moduledoc """
  Facade for outbound messaging. Delegates all calls to `AlexClaw.Gateway.Router`
  which resolves the correct transport (Telegram, Discord, etc.) based on opts.

  This is the primary entry point for sending messages from skills and the dispatcher.
  """

  @doc "Send a plain-text message via the resolved gateway."
  @spec send_message(String.t(), keyword()) :: :ok
  defdelegate send_message(text, opts \\ []), to: AlexClaw.Gateway.Router

  @doc "Send an HTML-formatted message via the resolved gateway."
  @spec send_html(String.t(), keyword()) :: :ok
  defdelegate send_html(text, opts \\ []), to: AlexClaw.Gateway.Router
end
