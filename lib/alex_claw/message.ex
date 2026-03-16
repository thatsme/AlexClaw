defmodule AlexClaw.Message do
  @moduledoc """
  Internal message struct normalized from Telegram updates.
  """
  defstruct [:text, :chat_id, :from, :timestamp, :raw]

  @type t :: %__MODULE__{
          text: String.t() | nil,
          chat_id: integer(),
          from: String.t() | nil,
          timestamp: DateTime.t(),
          raw: map()
        }
end
