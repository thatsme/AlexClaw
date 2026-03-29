defmodule AlexClaw.Workflows.LLMTransform do
  @moduledoc """
  Skill that runs a prompt template through the LLM.
  Handles template interpolation, provider selection, and tier routing.

  Accepts `prompt_template` from workflow step args or `prompt` from direct calls.
  Template placeholders: {input}, {context}, {resources}
  """
  @behaviour AlexClaw.Skill
  @impl true
  @spec description() :: String.t()
  def description, do: "Runs a prompt template through the LLM with tier and provider routing"
  require Logger

  @impl true
  @spec step_fields() :: [atom()]
  def step_fields, do: [:llm_tier, :llm_model, :prompt_template, :config]

  @impl true
  @spec config_hint() :: String.t()
  def config_hint, do: ~s|{"context": "extra context for {context} placeholder"}|

  @impl true
  @spec config_scaffold() :: map()
  def config_scaffold, do: %{"context" => "", "prompt" => ""}

  @impl true
  @spec config_presets() :: %{String.t() => map()}
  def config_presets do
    %{
      "Summarize" => %{"context" => "You are a concise summarizer."},
      "Translate" => %{"context" => "You are a translator."},
      "Classify" => %{"context" => "You are a content classifier."},
      "Extract" => %{"context" => "You extract structured data from text."}
    }
  end

  @impl true
  @spec prompt_presets() :: %{String.t() => String.t()}
  def prompt_presets do
    %{
      "Summarize" => "Summarize the following content concisely. Focus on key facts and main points.\n\n{input}",
      "Translate" => "Translate the following text to English. Preserve the original meaning and tone.\n\n{input}",
      "Classify" => "Classify the following content into one of these categories: [positive, negative, neutral].\nReturn only the category label.\n\n{input}",
      "Extract" => "Extract structured data from the following text. Return as JSON with relevant fields.\n\n{input}",
      "Q&A" => "Answer the following question based on the context provided.\n\nContext:\n{input}\n\nQuestion: {context}",
      "Rewrite" => "Rewrite the following content in a {context} tone. Keep the same facts.\n\n{input}",
      "Filter" => "Review the following content. If it contains relevant information about {context}, output it. Otherwise output SKIP.\n\n{input}"
    }
  end

  @impl true
  @spec config_help() :: String.t()
  def config_help, do: "context: extra text available as {context} in the prompt template. Usually empty — most config goes in the prompt."

  @impl true
  @spec prompt_help() :: String.t()
  def prompt_help, do: "Template sent to the LLM. Use {input} for previous step output, {context} for config context."

  @impl true
  @spec run(map()) :: {:ok, any(), atom()} | {:error, any()}
  def run(args) do
    template = args[:prompt_template] || args[:prompt] || args[:config]["prompt"] || ""

    if template == "" do
      {:ok, to_string_safe(args[:input]) || "", :on_success}
    else
      prompt = interpolate_template(template, args)
      tier = parse_tier(args[:llm_tier]) || :light
      provider = args[:llm_provider]

      llm_opts = [tier: tier]
      llm_opts = if provider && provider != "", do: Keyword.put(llm_opts, :provider, provider), else: llm_opts

      Logger.info("LLM Transform: #{String.slice(prompt, 0, 100)}...")

      case AlexClaw.LLM.complete(prompt, llm_opts) do
        {:ok, response} -> {:ok, response, :on_success}
        {:error, reason} -> {:error, reason}
      end
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
