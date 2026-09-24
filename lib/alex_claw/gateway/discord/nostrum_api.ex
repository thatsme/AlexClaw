defmodule AlexClaw.Gateway.Discord.NostrumAPI do
  @moduledoc "`AlexClaw.Gateway.Discord.API` through Nostrum's REST client: the default."
  @behaviour AlexClaw.Gateway.Discord.API

  alias Nostrum.Api.Message

  @impl true
  def create_message(channel_id, content), do: Message.create(channel_id, content: content)
end
