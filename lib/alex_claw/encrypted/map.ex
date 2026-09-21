defmodule AlexClaw.Encrypted.Map do
  @moduledoc """
  A JSON column stored with every string in it encrypted; its keys stay
  readable. See `AlexClaw.Encrypted`.
  """

  use Ecto.Type

  alias AlexClaw.Encrypted

  @impl true
  def type, do: :map

  @impl true
  def cast(value) when is_map(value) or is_nil(value), do: {:ok, value}
  def cast(_value), do: :error

  @impl true
  def dump(value) when is_map(value) or is_nil(value), do: {:ok, Encrypted.seal(value)}
  def dump(_value), do: :error

  @impl true
  def load(value) when is_map(value) or is_nil(value), do: {:ok, Encrypted.open!(value)}
  def load(_value), do: :error
end
