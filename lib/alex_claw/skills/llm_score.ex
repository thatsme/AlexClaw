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
  def routes, do: [:on_items, :on_empty, :on_error]

  require Logger
  import AlexClaw.Skills.Helpers, only: [parse_float: 2, parse_int: 2]

  @default_threshold 0.3
  @default_max_items 10

  @impl true
  def run(args) do
    config = args[:config] || %{}
    interests = config["interests"] || "general news, technology, finance, world events"
    threshold = parse_float(config["threshold"], @default_threshold)
    max_items = parse_int(config["max_items"], @default_max_items)

    items = parse_items(args[:input])

    llm_opts =
      case args[:llm_provider] do
        nil -> []
        "" -> []
        "auto" -> []
        provider -> [provider: provider]
      end

    llm_opts =
      case args[:llm_tier] do
        nil -> llm_opts
        tier when is_atom(tier) -> [{:tier, tier} | llm_opts]
        tier when is_binary(tier) -> [{:tier, String.to_existing_atom(tier)} | llm_opts]
      end

    # Default to :light tier for scoring if not specified
    llm_opts =
      if Keyword.has_key?(llm_opts, :tier), do: llm_opts, else: [{:tier, :light} | llm_opts]

    if items == [] do
      {:ok, "No items to score.", :on_empty}
    else
      case score_batch(items, interests, threshold, max_items, llm_opts) do
        {:ok, passed} when passed != [] ->
          {:ok, Jason.encode!(passed), :on_items}

        {:ok, []} ->
          {:ok, "No items passed the relevance threshold (#{threshold}).", :on_empty}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp parse_items(input) when is_binary(input) do
    case Jason.decode(input) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp parse_items(input) when is_list(input), do: input
  defp parse_items(_), do: []

  defp score_batch(items, interests, threshold, max_items, llm_opts) do
    numbered =
      items
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {item, i} ->
        title = item["title"] || Map.get(item, :title, "(no title)")
        "#{i}. #{title}"
      end)

    count = length(items)

    prompt = """
    You are a news relevance scorer. Rate each headline below from 0.0 (irrelevant) to 1.0 (highly relevant).

    Topics of interest: #{interests}

    Headlines:
    #{numbered}

    Rules:
    - Reply with exactly #{count} lines, one per headline, in the same order.
    - Each line must contain ONLY a decimal number (e.g. 0.8). No text, no numbering, no explanation.
    - Spread your scores: use the full 0.0-1.0 range. The most relevant item should be near 1.0, the least near 0.0.
    """

    Logger.info(
      "[LlmScore] Scoring #{count} items (interests: #{String.slice(interests, 0, 80)})",
      skill: :llm_score
    )

    case AlexClaw.LLM.complete(prompt, llm_opts) do
      {:ok, text} ->
        scores =
          text
          |> String.split(~r/[\n,]+/, trim: true)
          |> Enum.map(fn line ->
            line
            |> String.trim()
            |> String.replace(~r/^[\d]+[\.\):\-\s]+/, "")
            |> String.replace(~r/[^\d\.]/, "")
            |> Float.parse()
            |> case do
              {f, _} when f >= 0.0 and f <= 1.0 -> f
              {f, _} when f > 1.0 -> f / 10.0
              _ -> 0.0
            end
          end)

        scored =
          items
          |> Enum.with_index()
          |> Enum.map(fn {item, i} ->
            score = Enum.at(scores, i, 0.0)

            item
            |> then(fn
              m when is_map(m) -> Map.put(m, "score", score)
              other -> %{"item" => other, "score" => score}
            end)
          end)
          |> Enum.sort_by(&(&1["score"] || 0.0), :desc)

        passed =
          scored
          |> Enum.filter(&((&1["score"] || 0.0) >= threshold))
          |> Enum.take(max_items)

        Logger.info(
          "[LlmScore] Scored #{count} items, #{length(passed)} passed threshold #{threshold}",
          skill: :llm_score
        )

        {:ok, passed}

      {:error, reason} ->
        Logger.warning("[LlmScore] Scoring failed: #{inspect(reason)}", skill: :llm_score)
        {:error, {:scoring_failed, reason}}
    end
  end
end
