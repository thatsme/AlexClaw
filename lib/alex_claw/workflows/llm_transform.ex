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
  alias AlexClaw.Skills.Helpers

  @trimmed_note "\n\n[input trimmed to fit the model's context window]"

  @cite_instruction """

  Cite the items you mention by their number in brackets, like [1]. Do not write URLs: \
  the links are added from the numbers.
  """

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
    template = args[:prompt_template] || args[:prompt] || ""
    transform(template, args, linked_items(args[:input]))
  end

  # A step with no template used to return its input unchanged, which reads as a
  # step that worked: a reasoning plan ended with an llm_transform that handed
  # back the changelog it was given, and nothing was ever summarized.
  defp transform("", _args, _items), do: {:error, :no_prompt_template}
  defp transform(template, args, nil), do: complete(template, args)

  # Links come from the items, never from the model: feed text is untrusted,
  # and a model that writes URLs can mangle them or be told which to write.
  # The model sees the items numbered and without URLs, cites them by number,
  # and each citation becomes a link to that item's own link.
  defp transform(template, args, items) do
    with {:ok, reply, branch} <-
           complete(template <> @cite_instruction, Map.put(args, :input, numbered(items))) do
      {:ok, cite(reply, items), branch}
    end
  end

  defp complete(template, args) do
    build = &fitted_prompt(template, args, &1)

    case AlexClaw.LLM.complete_fitted(build, transform_opts(args)) do
      {:ok, response} -> {:ok, response, :on_success}
      {:error, reason} -> {:error, reason}
    end
  end

  # A list of items that each carry a "link": a JSON list, or an object with
  # "items" (rss_collector, rss_fetch, llm_score). nil for anything else.
  defp linked_items(input) when is_binary(input), do: input |> Jason.decode() |> decoded_items()
  defp linked_items(input) when is_list(input), do: items_of(input)
  defp linked_items(_input), do: nil

  defp decoded_items({:ok, document}), do: items_of(document)
  defp decoded_items({:error, _reason}), do: nil

  defp items_of(%{"items" => items}) when is_list(items), do: items_of(items)
  defp items_of([_ | _] = items), do: all_linked(Enum.all?(items, &linked?/1), items)
  defp items_of(_document), do: nil

  defp all_linked(true, items), do: items
  defp all_linked(false, _items), do: nil

  defp linked?(%{"link" => link}) when is_binary(link) and link != "", do: true
  defp linked?(_item), do: false

  defp numbered(items) do
    items
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {item, n} -> "[#{n}] " <> without_urls(item_line(item)) end)
  end

  defp item_line(item), do: line(to_string(item["title"] || "(no title)"), detail(item))

  defp line(title, ""), do: title
  defp line(title, detail), do: "#{title} — #{detail}"

  # rss_collector's items carry a plain-text "summary"; rss_fetch's carry the
  # feed's "description", often HTML.
  defp detail(%{"summary" => summary}) when is_binary(summary) and summary != "", do: summary

  defp detail(%{"description" => description}) when is_binary(description),
    do: Helpers.plain_text(description)

  defp detail(_item), do: ""

  # Model-written links lose their URL and keep their text; bare URLs go; each
  # [n] (or [n, m]) becomes a link to item n's link; a number that matches no
  # item is dropped.
  defp cite(reply, items) do
    links = items |> Enum.map(& &1["link"]) |> List.to_tuple()

    reply
    |> String.replace(~r/\[([^\]]*)\]\([^)]*\)/, "\\1")
    |> without_urls()
    |> String.replace(~r/[ \t]*\[(\d+(?:\s*,\s*\d+)*)\]/, &citation(&1, links))
  end

  defp citation(match, links) do
    ~r/\d+/
    |> Regex.scan(match)
    |> Enum.map(fn [n] -> String.to_integer(n) end)
    |> Enum.filter(&(&1 in 1..tuple_size(links)//1))
    |> Enum.map_join(fn n -> " [source](#{elem(links, n - 1)})" end)
  end

  defp without_urls(text), do: String.replace(text, ~r/(?:https?:\/\/|www\.)[^\s<>()\[\]]+/i, "")

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
