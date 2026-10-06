defmodule AlexClaw.Connections.InfiniteDate do
  @moduledoc """
  PostgreSQL's `date` for the database connections: Postgrex's own encoding
  and decoding, except that `'infinity'` and `'-infinity'` decode to `:inf`
  and `:"-inf"` instead of raising. A raise while a row is decoded stops the
  connection, and the connection's report quotes what it was decoding
  (reports/SQLREAD_ATTACKER_REVIEW.md M5).
  """
  import Postgrex.BinaryUtils, warn: false
  use Postgrex.BinaryExtension, send: "date_send"

  alias Postgrex.Extensions.Date, as: PgDate

  @doc false
  def encode(_state) do
    quote location: :keep do
      %Date{calendar: Calendar.ISO} = date ->
        Postgrex.Extensions.Date.encode_elixir(date)

      other ->
        raise DBConnection.EncodeError, Postgrex.Utils.encode_msg(other, Date)
    end
  end

  @doc false
  def decode(_state) do
    quote location: :keep do
      <<4::int32(), days::int32()>> ->
        unquote(__MODULE__).day_to_elixir(days)
    end
  end

  @doc false
  @spec day_to_elixir(integer()) :: Date.t() | :inf | :"-inf"
  def day_to_elixir(2_147_483_647), do: :inf
  def day_to_elixir(-2_147_483_648), do: :"-inf"
  def day_to_elixir(days), do: PgDate.day_to_elixir(days)
end

Postgrex.Types.define(
  AlexClaw.Connections.PostgrexTypes,
  [AlexClaw.Connections.InfiniteDate],
  allow_infinite_timestamps: true
)
