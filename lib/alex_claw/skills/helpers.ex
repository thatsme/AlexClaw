defmodule AlexClaw.Skills.Helpers do
  @moduledoc """
  Shared utility functions used across multiple modules.
  """

  @doc "Check if a value is nil or empty string."
  def blank?(nil), do: true
  def blank?(""), do: true
  def blank?(_), do: false

  @doc "Parse a string/integer to integer with a default fallback."
  def parse_int(nil, default), do: default
  def parse_int(val, _default) when is_integer(val), do: val

  def parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {i, _} -> i
      :error -> default
    end
  end

  def parse_int(_, default), do: default

  @doc "Parse a string/number to float with a default fallback."
  def parse_float(nil, default), do: default
  def parse_float(val, _default) when is_float(val), do: val
  def parse_float(val, _default) when is_integer(val), do: val / 1.0

  def parse_float(val, default) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> f
      :error -> default
    end
  end

  def parse_float(_, default), do: default

  @doc "Sanitize a binary to valid UTF-8, discarding invalid sequences."
  def sanitize_utf8(binary) do
    case :unicode.characters_to_binary(binary) do
      {:error, valid, _rest} -> valid
      {:incomplete, valid, _rest} -> valid
      valid when is_binary(valid) -> valid
    end
  end

  @doc "Strip noise elements (script, style, nav, footer, noscript, svg) from a parsed HTML document."
  def strip_noise(doc) do
    doc
    |> Floki.filter_out("script")
    |> Floki.filter_out("style")
    |> Floki.filter_out("nav")
    |> Floki.filter_out("header")
    |> Floki.filter_out("footer")
    |> Floki.filter_out("noscript")
    |> Floki.filter_out("svg")
  end
end
