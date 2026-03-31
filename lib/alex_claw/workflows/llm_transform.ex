defmodule AlexClaw.Workflows.LLMTransform do
  @moduledoc """
  Skill that runs a prompt template through the LLM.
  Handles template interpolation, provider selection, and tier routing.

  Accepts `prompt_template` from workflow step args or `prompt` from direct calls.
  Template placeholders: {input}, {resources}
  """
  @behaviour AlexClaw.Skill
  @impl true
  @spec description() :: String.t()
  def description, do: "Runs a prompt template through the LLM with tier and provider routing"

  @impl true
  @spec routes() :: [atom()]
  def routes, do: [:on_success, :on_error]

  require Logger

  @impl true
  @spec step_fields() :: [atom()]
  def step_fields, do: [:llm_tier, :llm_model, :prompt_template]

  @impl true
  @spec prompt_presets() :: %{String.t() => String.t()}
  def prompt_presets do
    %{
      "Summarize" => "Summarize the following content concisely. Focus on key facts and main points.\n\n{input}",
      "Bullet Points" => "Convert the following content into a clear bullet-point list. Group related items.\n\n{input}",
      "Security Review" => "You are a security-focused code reviewer. Analyse the following GitHub diff for security issues.\n\nFocus on: injection vulnerabilities, authentication bypass, secrets/credentials in code, insecure dependencies, path traversal, XSS, CSRF, SQL injection, hardcoded credentials, unsafe deserialization, missing input validation, privilege escalation.\n\n{input}\n\nReply in this exact format:\n\nRISK LEVEL: [CRITICAL|HIGH|MEDIUM|LOW|NONE]\n\nFINDINGS:\nList each finding as: [SEVERITY] Description — File:Line (if identifiable)\nIf no issues found, write: No security issues identified.\n\nSUMMARY:\n2-3 sentences on the overall security posture of this change.\n\nRECOMMENDATION:\nAPPROVE / REQUEST CHANGES / NEEDS FURTHER REVIEW — with one-line justification.",
      "Code Review" => "Review the following code changes. Focus on correctness, readability, and potential bugs. Ignore style.\n\n{input}\n\nFor each issue found:\n- File and line if identifiable\n- What the problem is\n- Suggested fix\n\nIf the code looks good, say so briefly.",
      "Translate" => "Translate the following text to English. Preserve the original meaning and tone.\n\n{input}",
      "Classify" => "Classify the following content into one of these categories: [positive, negative, neutral].\nReturn only the category label.\n\n{input}",
      "Extract JSON" => "Extract structured data from the following text. Return as JSON with relevant fields.\n\n{input}",
      "Changelog" => "Generate a changelog entry from the following diff or commit information. Group changes by type (added, changed, fixed, removed). Be concise.\n\n{input}",
      "Explain" => "Explain the following content in simple terms. Assume the reader has basic technical knowledge but is not an expert in this specific area.\n\n{input}",
      "Filter" => "Review the following content. If it contains relevant information, output it. Otherwise output SKIP.\n\n{input}",
      "Action Items" => "Extract actionable items from the following content. For each item, state: what needs to be done, who should do it (if mentioned), and priority (high/medium/low).\n\n{input}"
    }
  end

  @impl true
  @spec prompt_help() :: String.t()
  def prompt_help, do: "Template sent to the LLM. Use {input} for previous step output, {resources} for assigned resources."

  @impl true
  @spec run(map()) :: {:ok, any(), atom()} | {:error, any()}
  def run(args) do
    template = args[:prompt_template] || args[:prompt] || ""

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
    template
    |> String.replace("{input}", to_string_safe(args[:input]))
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
