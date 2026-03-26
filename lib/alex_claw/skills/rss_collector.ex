defmodule AlexClaw.Skills.RSSCollector do
  @moduledoc """
  Fetches RSS feeds, deduplicates, scores relevance via LLM,
  stores worthy items in memory, and notifies via Telegram.
  """
  @behaviour AlexClaw.Skill
  @impl true
  @spec description() :: String.t()
  def description,
    do: "Fetches RSS feeds, scores relevance via LLM, stores and notifies via Telegram"

  @impl true
  @spec routes() :: [atom()]
  def routes, do: [:on_items, :on_empty, :on_error]

  use Task, restart: :temporary
  require Logger

  import SweetXml
  import AlexClaw.Skills.Helpers, only: [parse_int: 2, parse_float: 2]

  alias AlexClaw.Config
  alias AlexClaw.Resources

  @spec start_link(map()) :: {:ok, pid()}
  def start_link(args) do
    Task.start_link(__MODULE__, :run, [args])
  end

  @impl true
  @spec run(map()) :: {:ok, map()} | {:error, term()}
  def run(args) do
    force = Map.get(args, :force, false)
    Logger.info("RSS Collector starting#{if force, do: " (force)", else: ""}", skill: :rss)

    config = args[:config] || %{}
    feeds = get_feeds(args)

    threshold =
      parse_float(config["threshold"], Config.get("skills.rss.relevance_threshold", 0.7))

    max_items = parse_int(config["max_items"], Config.get("skills.rss.max_items", 5))
    fetch_timeout = parse_int(config["fetch_timeout"], Config.get("skills.rss.fetch_timeout", 15))
    force = force || config["force"] == true

    llm_opts =
      case args[:llm_provider] do
        nil -> []
        "" -> []
        "auto" -> []
        provider -> [provider: provider]
      end

    recv_timeout = fetch_timeout * 1_000
    task_timeout = recv_timeout + 5_000

    fetched =
      feeds
      |> Task.async_stream(&fetch_feed(&1, recv_timeout),
        max_concurrency: 5,
        timeout: task_timeout,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, {:ok, items}} ->
          items

        {:ok, {:error, reason}} ->
          Logger.warning("Feed fetch failed: #{inspect(reason)}", skill: :rss)
          []

        {:exit, reason} ->
          Logger.warning("Feed fetch crashed: #{inspect(reason)}", skill: :rss)
          []
      end)

    results =
      if force do
        score_and_filter(fetched, threshold, max_items, llm_opts, config)
      else
        fetched
        |> Enum.reject(&already_seen?/1)
        |> score_and_filter(threshold, max_items, llm_opts, config)
      end

    Enum.each(results, fn item ->
      store_and_notify(item)
      Process.sleep(2_000)
    end)

    Logger.info("RSS Collector done: #{length(results)} items", skill: :rss)

    summary =
      Enum.map_join(results, "\n\n", fn item ->
        "**#{item.feed}**: #{item.title}\n#{String.slice(item.description || "", 0, 300)}\n#{item.link}"
      end)

    if summary == "" do
      {:ok, "No relevant news items found.", :on_empty}
    else
      {:ok, summary, :on_items}
    end
  end

  # --- Feed Fetching ---

  defp get_feeds(args) do
    # When called from a workflow, use resources passed in args
    case args[:resources] do
      resources when is_list(resources) and resources != [] ->
        resources
        |> Enum.filter(fn r -> r.type == "rss_feed" and r.enabled end)
        |> Enum.map(fn r -> {r.name, r.url} end)

      _ ->
        get_feeds_from_resources()
    end
  end

  defp get_feeds_from_resources do
    Enum.map(Resources.list_resources(%{type: "rss_feed", enabled: true}), fn r -> {r.name, r.url} end)
  end

  defp fetch_feed({name, url}, recv_timeout) do
    case Req.get(url, receive_timeout: recv_timeout, retry: false) do
      {:ok, %{status: 200, body: body}} ->
        items = parse_rss(name, body)
        {:ok, items}

      {:ok, %{status: status}} ->
        {:error, {:http, status, url}}

      {:error, reason} ->
        {:error, {name, reason}}
    end
  end

  defp parse_rss(feed_name, xml) when is_binary(xml) do
    xml
    |> xpath(~x"//item"l,
      title: ~x"./title/text()"s,
      link: ~x"./link/text()"s,
      description: ~x"./description/text()"s,
      pub_date: ~x"./pubDate/text()"s
    )
    |> Enum.map(fn item ->
      Map.put(item, :feed, feed_name)
    end)
  rescue
    e ->
      Logger.warning("RSS parse failed for #{feed_name}: #{Exception.message(e)}", skill: :rss)
      []
  catch
    :exit, reason ->
      Logger.warning("RSS XML parse exit for #{feed_name}: #{inspect(reason)}", skill: :rss)
      []
  end

  # --- Dedup ---

  defp already_seen?(item) do
    AlexClaw.Memory.exists?(item.link)
  end

  # --- Scoring (single LLM call with titles only) ---

  @max_items_to_score 20

  defp score_and_filter([], _threshold, _max_items, _llm_opts, _config), do: []

  defp score_and_filter(items, threshold, max_items, llm_opts, config) do
    interests =
      config["interests"] ||
        Config.get("prompts.rss.interests", "general news, technology, finance, world events")

    # Pre-filter: only recent items (last 48h) and limit total count
    items =
      items
      |> filter_recent(48)
      |> Enum.take(@max_items_to_score)

    if items == [] do
      []
    else
      score_single_call(items, interests, threshold, max_items, llm_opts)
    end
  end

  defp filter_recent(items, hours) do
    cutoff = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)

    Enum.filter(items, fn item ->
      case parse_pub_date(item.pub_date) do
        {:ok, dt} -> DateTime.compare(dt, cutoff) == :gt
        _ -> true
      end
    end)
  end

  defp parse_pub_date(nil), do: :error
  defp parse_pub_date(""), do: :error

  defp parse_pub_date(date_str) do
    case DateTime.from_iso8601(date_str) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> parse_rfc2822(date_str)
    end
  end

  defp parse_rfc2822(date_str) do
    # Best effort: extract date parts from RFC 2822
    case Regex.run(
           ~r/(\d{1,2})\s+(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+(\d{4})\s+(\d{2}):(\d{2})/,
           date_str
         ) do
      [_, day, month, year, hour, min] ->
        month_num = month_to_num(month)

        case NaiveDateTime.new(
               parse_int(year, 0),
               month_num,
               parse_int(day, 0),
               parse_int(hour, 0),
               parse_int(min, 0),
               0
             ) do
          {:ok, ndt} -> {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp month_to_num("Jan"), do: 1
  defp month_to_num("Feb"), do: 2
  defp month_to_num("Mar"), do: 3
  defp month_to_num("Apr"), do: 4
  defp month_to_num("May"), do: 5
  defp month_to_num("Jun"), do: 6
  defp month_to_num("Jul"), do: 7
  defp month_to_num("Aug"), do: 8
  defp month_to_num("Sep"), do: 9
  defp month_to_num("Oct"), do: 10
  defp month_to_num("Nov"), do: 11
  defp month_to_num("Dec"), do: 12

  defp score_single_call(items, interests, threshold, max_items, llm_opts) do
    numbered =
      items
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {item, i} ->
        "#{i}. #{item.title || "(no title)"}"
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
      "Scoring #{count} items in single LLM call (interests: #{String.slice(interests, 0, 80)})",
      skill: :rss
    )

    case AlexClaw.LLM.complete(prompt, llm_opts ++ [tier: :light]) do
      {:ok, text} ->
        Logger.info("Scoring response (first 500 chars): #{String.slice(text, 0, 500)}",
          skill: :rss
        )

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
            Map.put(item, :score, Enum.at(scores, i, 0.0))
          end)
          |> Enum.sort_by(& &1.score, :desc)

        # Relative selection: take top N items, but apply threshold as minimum floor
        passed =
          scored
          |> Enum.filter(&(&1.score >= threshold))
          |> Enum.take(max_items)

        Logger.info(
          "Top-#{max_items} (threshold: #{threshold}): scores=#{inspect(Enum.map(scored, & &1.score))}, passed=#{length(passed)}",
          skill: :rss
        )

        passed

      {:error, reason} ->
        Logger.warning("Scoring failed: #{inspect(reason)}", skill: :rss)
        []
    end
  end

  # --- Store & Notify ---

  defp escape_markdown(text) do
    # Strip chars that break Telegram legacy Markdown parsing
    String.replace(text, ~r/[*_`\[\]]/, "")
  end

  defp store_and_notify(item) do
    content = "#{item.title}\n#{item.description}"

    case AlexClaw.Memory.store(:news_item, content,
           source: item.link,
           metadata: %{feed: item.feed, score: item.score}
         ) do
      {:ok, _} -> :ok
      {:error, _} -> :already_stored
    end
  end
end
