defmodule AlexClaw.Identity do
  @moduledoc """
  Defines the agent's persona and behavioral rules.
  All prompts are read from AlexClaw.Config — zero hardcoded strings.
  """

  alias AlexClaw.Config

  @spec system_prompt(map()) :: String.t()
  def system_prompt(context \\ %{}) do
    name = Config.get("identity.name")
    custom = Config.get("identity.persona")

    base =
      (Config.get("identity.base_prompt") || "You are {name}, a personal AI agent.")
      |> String.replace("{name}", name || "Agent")

    fragment = context_fragment(context)

    [base, fragment, custom]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join("\n")
  end

  defp context_fragment(%{skill: skill}) when is_atom(skill) do
    Config.get("prompts.context.#{skill}")
  end

  defp context_fragment(_), do: nil
end
