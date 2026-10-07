defmodule AlexClaw.Connections.Types do
  @moduledoc """
  The PostgreSQL types a `sql_query` step supports, and their one mapping to
  and from JSON (reports/SQL_READ_PREMISES.md §4.3).

  A parameter arrives as a JSON value and is coerced to the type the server
  inferred for its `$n` — Postgrex encodes by that type and refuses a string
  for a date or an integer for a text. A result value is mapped to JSON by
  its column's type. Any other type is refused at save, naming it: cast it
  in the query (`::text`).
  """

  # OID => name, from pg_type: the types this release maps.
  @supported %{
    16 => "bool",
    19 => "name",
    20 => "int8",
    21 => "int2",
    23 => "int4",
    25 => "text",
    114 => "json",
    700 => "float4",
    701 => "float8",
    1042 => "bpchar",
    1043 => "varchar",
    1082 => "date",
    1114 => "timestamp",
    1184 => "timestamptz",
    1700 => "numeric",
    2950 => "uuid",
    3802 => "jsonb"
  }

  @integers ~w(int2 int4 int8)
  @floats ~w(float4 float8)
  @texts ~w(text varchar bpchar name)
  # PostgreSQL's infinite dates and timestamps come back as :inf / :"-inf".
  @dates ~w(date timestamp timestamptz)

  # Each integer type's range: a value outside it is refused here, never
  # left to the driver, whose error quotes it.
  @ranges %{
    "int2" => -32_768..32_767,
    "int4" => -2_147_483_648..2_147_483_647,
    "int8" => -9_223_372_036_854_775_808..9_223_372_036_854_775_807
  }

  @numeric_digits 131_072
  @numeric_scale 16_383

  # The largest integer a float can hold; beyond it the conversion fails.
  @max_float_integer Integer.pow(10, 308)

  @doc "The supported type's name for `oid`, or nil."
  @spec name(non_neg_integer()) :: String.t() | nil
  def name(oid), do: Map.get(@supported, oid)

  @doc """
  `value` (JSON) as the type `type` expects it, or why it does not fit.
  NULL fits every type.
  """
  @spec coerce(String.t(), term()) :: {:ok, term()} | {:error, String.t()}
  def coerce(_type, nil), do: {:ok, nil}

  def coerce(type, value) when type in @integers and is_integer(value),
    do: in_range(value in @ranges[type], value, type)

  def coerce(type, value) when type in @floats and is_float(value), do: {:ok, value}

  def coerce(type, value)
      when type in @floats and is_integer(value) and abs(value) <= @max_float_integer,
      do: {:ok, value * 1.0}

  def coerce(type, value) when type in @texts and is_binary(value), do: {:ok, value}
  def coerce("bool", value) when is_boolean(value), do: {:ok, value}
  def coerce(type, value) when type in ~w(json jsonb), do: encodable(Jason.encode(value), value)
  def coerce("numeric", value) when is_integer(value), do: numeric(Decimal.new(value))
  def coerce("numeric", value) when is_float(value), do: numeric(Decimal.from_float(value))

  def coerce("numeric", value) when is_binary(value) do
    with {:ok, decimal} <- parsed(Decimal.parse(value), "numeric"), do: numeric(decimal)
  end

  def coerce("uuid", value) when is_binary(value), do: dumped(Ecto.UUID.dump(value))
  def coerce("date", value) when is_binary(value), do: iso(Date.from_iso8601(value), "date")

  def coerce("timestamp", value) when is_binary(value),
    do: iso(NaiveDateTime.from_iso8601(value), "timestamp")

  def coerce("timestamptz", value) when is_binary(value),
    do: zoned(DateTime.from_iso8601(value))

  def coerce(type, _value), do: {:error, "expects #{expected(type)}"}

  defp in_range(true, value, _type), do: {:ok, value}
  defp in_range(false, _value, type), do: {:error, "is outside the range of #{type}"}

  defp encodable({:ok, _json}, value), do: {:ok, value}
  defp encodable({:error, _reason}, _value), do: {:error, "expects a JSON value"}

  # PostgreSQL's numeric holds up to 131072 digits before the point and 16383
  # after; beyond that the driver fails on it (F7). NaN and the infinities
  # are numeric values.
  defp numeric(%Decimal{coef: coef, exp: exp} = decimal) when is_integer(coef) do
    digits = coef |> Integer.to_string() |> byte_size()

    if exp >= -@numeric_scale and digits + exp <= @numeric_digits,
      do: {:ok, decimal},
      else: {:error, "is outside the range of numeric"}
  end

  defp numeric(decimal), do: {:ok, decimal}

  defp parsed({decimal, ""}, _type), do: {:ok, decimal}
  defp parsed(_other, type), do: {:error, "expects #{expected(type)}"}

  defp dumped({:ok, binary}), do: {:ok, binary}
  defp dumped(:error), do: {:error, "expects #{expected("uuid")}"}

  defp iso({:ok, value}, _type), do: {:ok, value}
  defp iso({:error, _reason}, type), do: {:error, "expects #{expected(type)}"}

  defp zoned({:ok, datetime, _offset}), do: {:ok, DateTime.shift_zone!(datetime, "Etc/UTC")}
  defp zoned({:error, _reason}), do: {:error, "expects #{expected("timestamptz")}"}

  defp expected(type) when type in @integers, do: "an integer"
  defp expected(type) when type in @floats, do: "a number"
  defp expected(type) when type in @texts, do: "a string"
  defp expected("bool"), do: "true or false"
  defp expected("numeric"), do: "a number or a numeric string"
  defp expected("uuid"), do: "a UUID string"
  defp expected("date"), do: "a date, YYYY-MM-DD"
  defp expected("timestamp"), do: "an ISO 8601 date-time without a zone"
  defp expected("timestamptz"), do: "an ISO 8601 date-time with a zone"
  defp expected(type), do: "a supported type (#{type} is not)"

  @doc "A result value of type `type` as JSON."
  @spec to_json(String.t(), term()) :: term()
  def to_json(_type, nil), do: nil
  def to_json(type, :inf) when type in @dates, do: "infinity"
  def to_json(type, :"-inf") when type in @dates, do: "-infinity"
  def to_json("numeric", %Decimal{} = value), do: Decimal.to_string(value, :normal)
  def to_json("uuid", <<_::128>> = value), do: Ecto.UUID.cast!(value)
  def to_json("date", %Date{} = value), do: Date.to_iso8601(value)

  def to_json("timestamp", %NaiveDateTime{} = value),
    do: value |> whole_second(NaiveDateTime) |> NaiveDateTime.to_iso8601()

  def to_json("timestamptz", %DateTime{} = value),
    do: value |> whole_second(DateTime) |> DateTime.to_iso8601()

  # Infinity and NaN have no JSON number.
  def to_json(type, value) when type in @floats and is_atom(value), do: Atom.to_string(value)
  def to_json(_type, value), do: value

  # The database's precision is microseconds: a whole second is written
  # without a fraction, any other value with all six digits.
  defp whole_second(%{microsecond: {0, _precision}} = value, module),
    do: module.truncate(value, :second)

  defp whole_second(value, _module), do: value
end
