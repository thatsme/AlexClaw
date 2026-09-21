defmodule AlexClaw.Encrypted.Text do
  @moduledoc "A text column stored encrypted. See `AlexClaw.Encrypted`."

  use Ecto.Type

  alias AlexClaw.Encrypted

  @impl true
  def type, do: :string

  @impl true
  def cast(value) when is_binary(value) or is_nil(value), do: {:ok, value}
  def cast(_value), do: :error

  @impl true
  def dump(value) when is_binary(value) or is_nil(value), do: {:ok, Encrypted.seal(value)}
  def dump(_value), do: :error

  @impl true
  def load(value), do: {:ok, Encrypted.open!(value)}
end
