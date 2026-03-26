defmodule AlexClaw.Dispatcher.CommandParser do
  @moduledoc """
  Parses --flag value pairs from command text.
  Returns {remaining_text, opts_keyword_list}.

  Example:
    parse("--tier heavy --provider gemini what is BEAM?")
    => {"what is BEAM?", [tier: "heavy", provider: "gemini"]}
  """

  @known_flags ~w(tier provider)

  @spec parse(String.t()) :: {String.t(), keyword()}
  def parse(text) do
    parts = String.split(text, " ")
    {flags, rest} = extract_flags(parts, [], [])
    {String.trim(Enum.join(rest, " ")), flags}
  end

  @doc "Resolve tier: command flag > Config > hardcoded default."
  @spec resolve_tier(keyword(), String.t(), String.t()) :: atom()
  def resolve_tier(opts, config_key, default) do
    case Keyword.get(opts, :tier) do
      nil -> to_tier(AlexClaw.Config.get(config_key) || default)
      val -> to_tier(val)
    end
  end

  @doc "Resolve provider: command flag > Config > auto."
  @spec resolve_provider(keyword(), String.t()) :: String.t() | nil
  def resolve_provider(opts, config_key) do
    case Keyword.get(opts, :provider) do
      nil -> AlexClaw.Config.get(config_key) || "auto"
      val -> val
    end
  end

  @doc "Check if a flag was passed without a value (query mode)."
  @spec query_flag?(String.t(), String.t()) :: boolean()
  def query_flag?(text, flag) do
    text == "--#{flag}" or String.starts_with?(text, "--#{flag} ") and
      not Regex.match?(~r/--#{flag}\s+\S/, text)
  end

  defp to_tier(val) when is_atom(val), do: val
  defp to_tier(val) when is_binary(val), do: String.to_existing_atom(val)

  defp extract_flags([], flags, rest), do: {Enum.reverse(flags), Enum.reverse(rest)}

  defp extract_flags(["--" <> flag], flags, rest) when flag in @known_flags do
    # Flag with no value — mark as query
    {Enum.reverse([{String.to_existing_atom(flag), :query} | flags]), Enum.reverse(rest)}
  end

  defp extract_flags(["--" <> flag, value | tail], flags, rest) when flag in @known_flags do
    extract_flags(tail, [{String.to_existing_atom(flag), value} | flags], rest)
  end

  defp extract_flags([head | tail], flags, rest) do
    extract_flags(tail, flags, [head | rest])
  end
end
