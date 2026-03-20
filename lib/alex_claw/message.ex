defmodule AlexClaw.Message do
  @moduledoc """
  Internal message struct normalized from gateway updates.
  The :gateway field identifies the originating transport (:telegram, :discord, etc.).
  """
  defstruct [:text, :chat_id, :from, :timestamp, :raw, :gateway]

  @type t :: %__MODULE__{
          text: String.t() | nil,
          chat_id: integer() | String.t(),
          from: String.t() | nil,
          timestamp: DateTime.t(),
          raw: map(),
          gateway: atom() | nil
        }
end
