defmodule AlexClaw.Skills.Helpers do
  @moduledoc """
  Shared utility functions used across multiple modules.
  """

  @doc "Check if a value is nil or empty string."
  @spec blank?(any()) :: boolean()
  def blank?(nil), do: true
  def blank?(""), do: true
  def blank?(_), do: false

  @doc "Parse a string/integer to integer with a default fallback."
  @spec parse_int(any(), integer()) :: integer()
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
  @spec parse_float(any(), number()) :: float()
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
  @spec sanitize_utf8(binary()) :: binary()
  def sanitize_utf8(binary) do
    case :unicode.characters_to_binary(binary) do
      {:error, valid, _rest} -> valid
      {:incomplete, valid, _rest} -> valid
      valid when is_binary(valid) -> valid
    end
  end

  @doc "Strip noise elements (script, style, nav, footer, noscript, svg) from a parsed HTML document."
  @spec strip_noise(Floki.html_tree()) :: Floki.html_tree()
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

  @doc "The text of an HTML fragment, with runs of whitespace collapsed to one space."
  @spec plain_text(String.t()) :: String.t()
  def plain_text(html) do
    html
    |> fragment_text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp fragment_text(html) do
    case Floki.parse_fragment(html) do
      {:ok, tree} -> Floki.text(tree, sep: " ")
      {:error, _reason} -> Regex.replace(~r/<[^>]*>/, html, " ")
    end
  end

  @doc """
  Build the LLM option list a skill passes to `AlexClaw.LLM`, from the provider and
  tier a workflow step supplies. `default_tier` applies when the step names none;
  `"auto"` and blank providers mean "let the router choose".
  """
  @spec llm_opts(map(), atom() | nil) :: keyword()
  def llm_opts(args, default_tier \\ nil) do
    args[:llm_provider]
    |> provider_opts()
    |> tier_opts(args[:llm_tier] || default_tier)
  end

  @doc """
  Read a model's scoring reply: one score per line (or comma-separated), in
  item order. Each is a float in 0.0–1.0, or `nil` for a line with no number.

  "0.8", "1. 0.8", "2) 0.8" and "0.8 — relevant" all read 0.8. A list number
  is stripped only when whitespace follows it: stripping "0." from "0.1" read
  it as 1.0. A score on a 0–10 scale is rescaled.
  """
  @spec parse_scores(String.t()) :: [float() | nil]
  def parse_scores(text) do
    text
    |> String.split(~r/[\n,]+/, trim: true)
    |> Enum.map(&parse_score_line/1)
  end

  defp parse_score_line(line) do
    line
    |> String.trim()
    |> String.replace(~r/^\d+[\.\):]\s+/, "")
    |> first_number()
    |> normalize_score()
  end

  defp first_number(text) do
    case Regex.run(~r/\d+(?:\.\d+)?/, text) do
      [number] -> Float.parse(number)
      nil -> :error
    end
  end

  defp normalize_score({f, _rest}) when f >= 0.0 and f <= 1.0, do: f
  defp normalize_score({f, _rest}) when f > 1.0, do: f / 10.0
  defp normalize_score(_), do: nil

  defp provider_opts(provider) when provider in [nil, "", "auto"], do: []
  defp provider_opts(provider), do: [provider: provider]

  defp tier_opts(opts, nil), do: opts
  defp tier_opts(opts, tier) when is_atom(tier), do: [{:tier, tier} | opts]

  defp tier_opts(opts, tier) when is_binary(tier) do
    [{:tier, String.to_existing_atom(tier)} | opts]
  end
end
