defmodule AlexClaw.Skills.LlmScore do
  @moduledoc """
  Batch item scoring skill. Takes a list of items and scores them for
  relevance using a single LLM call. Returns items that pass the threshold.

  Works with any list of items that have a "title" field.
  Designed to pair with `rss_fetch`:
    rss_fetch → llm_score → llm_transform → telegram_notify
  """
  @behaviour AlexClaw.Skill
  @impl true
  def description, do: "Scores items for relevance via batch LLM call, filters by threshold"

  @impl true
  @spec routes() :: [atom()]
  def routes, do: [:on_items, :on_empty, :on_error]

  require Logger
  import AlexClaw.Skills.Helpers, only: [llm_opts: 2, parse_float: 2, parse_int: 2]

  @default_threshold 0.3
  @default_max_items 10

  @impl true
  @spec step_fields() :: [atom()]
  def step_fields, do: [:llm_tier, :llm_model, :config]

  @impl true
  @spec config_hint() :: String.t()
  def config_hint, do: ~s|{"interests": "AI, cybersecurity", "threshold": 0.3, "max_items": 10}|

  @impl true
  @spec config_scaffold() :: map()
  def config_scaffold, do: %{"interests" => "", "threshold" => 0.3, "max_items" => 10}

  @impl true
  @spec config_presets() :: %{String.t() => map()}
  def config_presets do
    %{
      "News" => %{
        "interests" => "AI, cybersecurity, Elixir, finance",
        "threshold" => 0.3,
        "max_items" => 10
      },
      "Strict" => %{
        "interests" => "AI, cybersecurity, Elixir, finance",
        "threshold" => 0.7,
        "max_items" => 5
      }
    }
  end

  @impl true
  @spec config_help() :: String.t()
  def config_help,
    do:
      "interests: topics for relevance scoring. threshold: minimum score 0-1 (default 0.3). max_items: max items to return. Scores items via single batch LLM call."

  @impl true
  @spec run(map()) :: {:ok, any(), atom()} | {:error, any()}
  def run(args) do
    config = args[:config] || %{}
    threshold = parse_float(config["threshold"], @default_threshold)

    score_items(
      parse_items(args[:input]),
      config["interests"] || "general news, technology, finance, world events",
      threshold,
      parse_int(config["max_items"], @default_max_items),
      # Scoring defaults to the :light tier unless the step names one.
      llm_opts(args, :light)
    )
  end

  defp score_items([], _interests, _threshold, _max_items, _llm_opts) do
    {:ok, "No items to score.", :on_empty}
  end

  defp score_items(items, interests, threshold, max_items, llm_opts) do
    items
    |> score_batch(interests, threshold, max_items, llm_opts)
    |> scored_result(threshold)
  end

  defp scored_result({:ok, []}, threshold) do
    {:ok, "No items passed the relevance threshold (#{threshold}).", :on_empty}
  end

  defp scored_result({:ok, passed}, _threshold), do: {:ok, Jason.encode!(passed), :on_items}
  defp scored_result({:error, reason}, _threshold), do: {:error, reason}

  defp parse_items(input) when is_binary(input) do
    case Jason.decode(input) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp parse_items(input) when is_list(input), do: input
  defp parse_items(_), do: []

  defp score_batch(items, interests, threshold, max_items, llm_opts) do
    count = length(items)

    Logger.info(
      "[LlmScore] Scoring #{count} items (interests: #{String.slice(interests, 0, 80)})",
      skill: :llm_score
    )

    interests
    |> scoring_prompt(items, count)
    |> AlexClaw.LLM.complete(llm_opts)
    |> apply_scores(items, threshold, max_items, count)
  end

  defp scoring_prompt(interests, items, count) do
    numbered =
      items
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {item, i} ->
        "#{i}. #{item["title"] || Map.get(item, :title, "(no title)")}"
      end)

    """
    You are a news relevance scorer. Rate each headline below from 0.0 (irrelevant) to 1.0 (highly relevant).

    Topics of interest: #{interests}

    Headlines:
    #{numbered}

    Rules:
    - Reply with exactly #{count} lines, one per headline, in the same order.
    - Each line must contain ONLY a decimal number (e.g. 0.8). No text, no numbering, no explanation.
    - Spread your scores: use the full 0.0-1.0 range. The most relevant item should be near 1.0, the least near 0.0.
    """
  end

  defp apply_scores({:error, reason}, _items, _threshold, _max_items, _count) do
    Logger.warning("[LlmScore] Scoring failed: #{inspect(reason)}", skill: :llm_score)
    {:error, {:scoring_failed, reason}}
  end

  defp apply_scores({:ok, text}, items, threshold, max_items, count) do
    scores = parse_scores(text)

    passed =
      items
      |> Enum.with_index()
      |> Enum.map(fn {item, i} -> with_score(item, Enum.at(scores, i, 0.0)) end)
      |> Enum.sort_by(&(&1["score"] || 0.0), :desc)
      |> Enum.filter(&((&1["score"] || 0.0) >= threshold))
      |> Enum.take(max_items)

    Logger.info(
      "[LlmScore] Scored #{count} items, #{length(passed)} passed threshold #{threshold}",
      skill: :llm_score
    )

    {:ok, passed}
  end

  defp parse_scores(text) do
    text
    |> String.split(~r/[\n,]+/, trim: true)
    |> Enum.map(&parse_score_line/1)
  end

  # "0.8", "1. 0.8", "2) 0.8" and "0.8 — relevant" all read 0.8. A list number
  # is only stripped when whitespace follows it: stripping "0." from "0.1" read
  # it as 1.0, and "1.0" as 0.
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

  # A model that answers on a 0-10 scale despite the instruction is rescaled
  # rather than discarded.
  defp normalize_score({f, _rest}) when f >= 0.0 and f <= 1.0, do: f
  defp normalize_score({f, _rest}) when f > 1.0, do: f / 10.0
  defp normalize_score(_), do: 0.0

  defp with_score(item, score) when is_map(item), do: Map.put(item, "score", score)
  defp with_score(item, score), do: %{"item" => item, "score" => score}
end
