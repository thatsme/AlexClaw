defmodule AlexClaw.Message do
  @moduledoc """
  Internal message struct normalized from gateway updates.
  The :gateway field identifies the originating transport (:telegram, :discord, etc.).
  """
  @enforce_keys [:chat_id, :timestamp, :raw, :gateway]
  defstruct [:text, :chat_id, :user_id, :from, :timestamp, :raw, :gateway]

  @type t :: %__MODULE__{
          text: String.t() | nil,
          chat_id: integer() | String.t(),
          user_id: integer() | String.t() | nil,
          from: String.t() | nil,
          timestamp: DateTime.t(),
          raw: map(),
          gateway: atom() | nil
        }
end
