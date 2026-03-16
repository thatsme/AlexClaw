defmodule AlexClaw.Workflows.LLMTransform do
  @moduledoc """
  Skill that runs a prompt template through the LLM.
  Handles template interpolation, provider selection, and tier routing.

  Accepts `prompt_template` from workflow step args or `prompt` from direct calls.
  Template placeholders: {input}, {context}, {resources}
  """
  @behaviour AlexClaw.Skill
  @impl true
  def description, do: "Runs a prompt template through the LLM with tier and provider routing"
  require Logger

  @impl true
  def run(args) do
    template = args[:prompt_template] || args[:prompt] || args[:config]["prompt"] || ""

    if template == "" do
      {:ok, to_string_safe(args[:input]) || ""}
    else
      prompt = interpolate_template(template, args)
      tier = parse_tier(args[:llm_tier]) || :light
      provider = args[:llm_provider]

      llm_opts = [tier: tier]
      llm_opts = if provider && provider != "", do: Keyword.put(llm_opts, :provider, provider), else: llm_opts

      Logger.info("LLM Transform: #{String.slice(prompt, 0, 100)}...")

      AlexClaw.LLM.complete(prompt, llm_opts)
    end
  end

  defp interpolate_template(template, args) do
    config = args[:config] || %{}

    template
    |> String.replace("{input}", to_string_safe(args[:input]))
    |> String.replace("{context}", to_string_safe(config["context"]))
    |> String.replace("{resources}", format_resources(args[:resources]))
  end

  defp format_resources(resources) when is_list(resources) do
    resources
    |> Enum.map(fn r -> "- #{r.name} (#{r.type}): #{r.url || "inline"}" end)
    |> Enum.join("\n")
  end

  defp format_resources(_), do: ""

  defp to_string_safe(nil), do: ""
  defp to_string_safe(val) when is_binary(val), do: val
  defp to_string_safe(val) when is_map(val), do: Jason.encode!(val)
  defp to_string_safe(val), do: inspect(val)

  defp parse_tier("light"), do: :light
  defp parse_tier("medium"), do: :medium
  defp parse_tier("heavy"), do: :heavy
  defp parse_tier("local"), do: :local
  defp parse_tier(_), do: nil
end
