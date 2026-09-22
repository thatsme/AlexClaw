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

  alias AlexClaw.LLM.Window

  @trimmed_note "\n\n[input trimmed to fit the model's context window]"

  @impl true
  @spec step_fields() :: [atom()]
  def step_fields, do: [:llm_tier, :llm_model, :prompt_template]

  @impl true
  @spec prompt_presets() :: %{String.t() => String.t()}
  def prompt_presets do
    %{
      "Summarize" =>
        "Summarize the following content concisely. Focus on key facts and main points.\n\n{input}",
      "Bullet Points" =>
        "Convert the following content into a clear bullet-point list. Group related items.\n\n{input}",
      "Security Review" =>
        "You are a security-focused code reviewer. Analyse the following GitHub diff for security issues.\n\nFocus on: injection vulnerabilities, authentication bypass, secrets/credentials in code, insecure dependencies, path traversal, XSS, CSRF, SQL injection, hardcoded credentials, unsafe deserialization, missing input validation, privilege escalation.\n\n{input}\n\nReply in this exact format:\n\nRISK LEVEL: [CRITICAL|HIGH|MEDIUM|LOW|NONE]\n\nFINDINGS:\nList each finding as: [SEVERITY] Description — File:Line (if identifiable)\nIf no issues found, write: No security issues identified.\n\nSUMMARY:\n2-3 sentences on the overall security posture of this change.\n\nRECOMMENDATION:\nAPPROVE / REQUEST CHANGES / NEEDS FURTHER REVIEW — with one-line justification.",
      "Code Review" =>
        "Review the following code changes. Focus on correctness, readability, and potential bugs. Ignore style.\n\n{input}\n\nFor each issue found:\n- File and line if identifiable\n- What the problem is\n- Suggested fix\n\nIf the code looks good, say so briefly.",
      "Translate" =>
        "Translate the following text to English. Preserve the original meaning and tone.\n\n{input}",
      "Classify" =>
        "Classify the following content into one of these categories: [positive, negative, neutral].\nReturn only the category label.\n\n{input}",
      "Extract JSON" =>
        "Extract structured data from the following text. Return as JSON with relevant fields.\n\n{input}",
      "Changelog" =>
        "Generate a changelog entry from the following diff or commit information. Group changes by type (added, changed, fixed, removed). Be concise.\n\n{input}",
      "Explain" =>
        "Explain the following content in simple terms. Assume the reader has basic technical knowledge but is not an expert in this specific area.\n\n{input}",
      "Filter" =>
        "Review the following content. If it contains relevant information, output it. Otherwise output SKIP.\n\n{input}",
      "Action Items" =>
        "Extract actionable items from the following content. For each item, state: what needs to be done, who should do it (if mentioned), and priority (high/medium/low).\n\n{input}"
    }
  end

  @impl true
  @spec prompt_help() :: String.t()
  def prompt_help,
    do:
      "Template sent to the LLM. Use {input} for previous step output, {resources} for assigned resources."

  @impl true
  @spec run(map()) :: {:ok, any(), atom()} | {:error, any()}
  def run(args) do
    transform(args[:prompt_template] || args[:prompt] || "", args)
  end

  # A step with no template used to return its input unchanged, which reads as a
  # step that worked: a reasoning plan ended with an llm_transform that handed
  # back the changelog it was given, and nothing was ever summarized.
  defp transform("", _args), do: {:error, :no_prompt_template}

  defp transform(template, args) do
    build = &fitted_prompt(template, args, &1)

    case AlexClaw.LLM.complete_fitted(build, transform_opts(args)) do
      {:ok, response} -> {:ok, response, :on_success}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The prompt for one provider's budget: the template always, and as much of the
  input as is left. A diff or a page longer than the window is cut here, where
  it can be said, rather than by the model's server. `{:error, {:does_not_fit,
  tokens}}` when the template alone is larger than the budget.
  """
  @spec fitted_prompt(String.t(), map(), non_neg_integer() | :unlimited) ::
          {:ok, String.t()} | {:error, {:does_not_fit, non_neg_integer()}}
  def fitted_prompt(template, args, :unlimited),
    do: {:ok, logged(interpolate_template(template, args, to_string_safe(args[:input])))}

  def fitted_prompt(template, args, budget) do
    input = to_string_safe(args[:input])
    mandatory = Window.estimate(interpolate_template(template, args, ""))

    case budget - mandatory do
      room when room <= 0 -> {:error, {:does_not_fit, mandatory}}
      room -> {:ok, logged(interpolate_template(template, args, within(input, room)))}
    end
  end

  # Three bytes per token, the estimate Window uses, and a line saying what was cut.
  defp within(input, room) do
    allowed = room * 3 - byte_size(@trimmed_note)

    case byte_size(input) > allowed do
      false -> input
      true -> String.slice(input, 0, max(allowed, 0)) <> @trimmed_note
    end
  end

  defp logged(prompt) do
    Logger.info("LLM Transform: #{String.slice(prompt, 0, 100)}...")
    prompt
  end

  defp transform_opts(args) do
    put_provider([tier: parse_tier(args[:llm_tier]) || :light], args[:llm_provider])
  end

  defp put_provider(opts, provider) when provider in [nil, ""], do: opts
  defp put_provider(opts, provider), do: Keyword.put(opts, :provider, provider)

  defp interpolate_template(template, args, input) do
    template
    |> String.replace("{input}", input)
    |> String.replace("{resources}", format_resources(args[:resources]))
  end

  defp format_resources(resources) when is_list(resources) do
    resources
    |> Enum.map_join("\n", fn r -> "- #{r.name} (#{r.type}): #{r.url || "inline"}" end)
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
