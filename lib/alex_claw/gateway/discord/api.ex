defmodule AlexClaw.Gateway.Discord.API do
  @moduledoc """
  The Discord REST calls the gateway makes, behind one behaviour so the
  implementation can be chosen with the `:discord_api` application setting.
  """

  @doc "Post `content` to the channel `channel_id`."
  @callback create_message(channel_id :: integer(), content :: String.t()) ::
              {:ok, term()} | {:error, term()}
end
