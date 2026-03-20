defmodule AlexClaw.Gateway do
  @moduledoc """
  Facade for backward compatibility. Delegates all calls to the Gateway Router
  which resolves the correct transport (Telegram, Discord, etc.) based on opts.
  """

  defdelegate send_message(text, opts \\ []), to: AlexClaw.Gateway.Router
  defdelegate send_html(text, opts \\ []), to: AlexClaw.Gateway.Router
end
