defmodule AlexClaw.Gateway.Behaviour do
  @moduledoc "Contract for all messaging gateways (Telegram, Discord, etc.)."

  @callback send_message(text :: String.t(), opts :: keyword()) :: :ok
  @callback send_html(text :: String.t(), opts :: keyword()) :: :ok
  @callback send_photo(chat_id :: term(), photo_data :: binary(), caption :: String.t()) ::
              :ok | {:error, term()}
  @callback name() :: atom()
  @callback configured?() :: boolean()
end
