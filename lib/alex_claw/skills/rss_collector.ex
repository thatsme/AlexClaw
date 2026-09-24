defmodule AlexClaw.Skills.RSSCollector do
  @moduledoc """
  Fetches RSS feeds, deduplicates, scores relevance via LLM,
  stores worthy items in memory, and notifies via Telegram.
  """
  @behaviour AlexClaw.Skill
  @impl true
  @spec external() :: boolean()
  def external, do: true
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

  import AlexClaw.Skills.Helpers,
    only: [parse_int: 2, parse_float: 2, parse_scores: 1, plain_text: 1]

  alias AlexClaw.Config
  alias AlexClaw.Resources

  @spec start_link(map()) :: {:ok, pid()}
  def start_link(args) do
    Task.start_link(__MODULE__, :run, [args])
  end

  @impl true
  @spec step_fields() :: [atom()]
  def step_fields, do: [:llm_tier, :llm_model, :config]

  @impl true
  @spec config_hint() :: String.t()
  def config_hint, do: ~s|{"force": false, "max_items": 5, "fetch_timeout": 15}|

  @impl true
  @spec config_scaffold() :: map()
  def config_scaffold, do: %{"force" => false, "max_items" => 5, "fetch_timeout" => 15}

  @impl true
  @spec config_help() :: String.t()
  def config_help,
    do:
      "force: re-fetch even if cached. max_items: limit results. fetch_timeout: seconds per feed (default 15). For scoring, use rss_fetch → llm_score instead."

  @impl true
  @spec run(map()) :: {:ok, String.t(), atom()} | {:error, term()}
  def run(args) do
    force = Map.get(args, :force, false)
    Logger.info("RSS Collector starting#{if force, do: " (force)", else: ""}", skill: :rss)

    config = args[:config] || %{}
    fetch_timeout = parse_int(config["fetch_timeout"], Config.get("skills.rss.fetch_timeout", 15))

    opts = %{
      threshold:
        parse_float(config["threshold"], Config.get("skills.rss.relevance_threshold", 0.7)),
      max_items: parse_int(config["max_items"], Config.get("skills.rss.max_items", 5)),
      llm_opts: provider_opts(args[:llm_provider]) ++ tier_opts(args[:llm_tier]),
      config: config
    }

    with {:ok, feeds} <- get_feeds(args),
         {:ok, fetched, dead} <- fetch_all(feeds, fetch_timeout * 1_000),
         {:ok, selected} <- select_items(fetched, force || config["force"] == true, opts) do
      deliver(selected, dead)
    end
  end

  defp provider_opts(provider) when provider in [nil, "", "auto"], do: []
  defp provider_opts(provider), do: [provider: provider]

  defp tier_opts(tier) when tier in ~w(local light medium heavy),
    do: [tier: String.to_existing_atom(tier)]

  defp tier_opts(_tier), do: []

  # A feed that cannot be fetched or read is skipped, and named in the output;
  # when every feed fails, the step fails. Results come back in feed order.
  defp fetch_all(feeds, recv_timeout) do
    feeds
    |> Task.async_stream(&fetch_feed(&1, recv_timeout),
      max_concurrency: 5,
      timeout: recv_timeout + 5_000,
      on_timeout: :kill_task
    )
    |> Enum.zip(feeds)
    |> Enum.map(&feed_result/1)
    |> Enum.split_with(&match?({:ok, _items}, &1))
    |> fetched()
  end

  defp fetched({[], dead}),
    do: {:error, {:all_feeds_failed, Enum.map(dead, fn {:error, {_name, url}} -> url end)}}

  defp fetched({live, dead}) do
    items =
      live
      |> Enum.flat_map(&elem(&1, 1))
      |> Enum.filter(&complete?/1)

    {:ok, items, Enum.map(dead, &elem(&1, 1))}
  end

  # An item without a title has nothing to score; one without a link cannot
  # be deduplicated or opened.
  defp complete?(%{title: title, link: link}), do: title != "" and link != ""

  defp feed_result({{:ok, {:ok, items}}, _feed}), do: {:ok, items}

  defp feed_result({{:ok, {:error, reason}}, {name, url}}) do
    Logger.warning("Feed #{url} failed: #{inspect(reason)}", skill: :rss)
    {:error, {name, url}}
  end

  defp feed_result({{:exit, reason}, {name, url}}) do
    Logger.warning("Feed #{url} crashed: #{inspect(reason)}", skill: :rss)
    {:error, {name, url}}
  end

  # force bypasses the seen-item filter and rescores everything fetched.
  defp select_items(fetched, true, opts) do
    score_and_filter(fetched, opts.threshold, opts.max_items, opts.llm_opts, opts.config)
  end

  defp select_items(fetched, false, opts) do
    fetched
    |> Enum.reject(&already_seen?/1)
    |> score_and_filter(opts.threshold, opts.max_items, opts.llm_opts, opts.config)
  end

  defp deliver(results, dead) do
    Enum.each(results, fn item ->
      store_and_notify(item)
      Process.sleep(2_000)
    end)

    Logger.info("RSS Collector done: #{length(results)} items", skill: :rss)
    summarize(results, dead)
  end

  # JSON, like rss_fetch's output, so the executor's sanitizer treats each field
  # on its own: a text block with raw description HTML was read as one HTML
  # document, which flattened the items and let a description cut inside a tag
  # swallow the next item.
  defp summarize(results, dead) do
    output = %{
      "items" => Enum.map(results, &item_json/1),
      "skipped" => Enum.map(dead, fn {name, url} -> %{"feed" => name, "url" => url} end)
    }

    {:ok, Jason.encode!(output), branch(results)}
  end

  defp branch([]), do: :on_empty
  defp branch(_results), do: :on_items

  defp item_json(item) do
    %{
      "feed" => item.feed,
      "title" => item.title,
      "summary" => summary(item.description),
      "link" => item.link
    }
  end

  # The HTML is removed before the text is shortened, so no cut lands in a tag.
  defp summary(description) do
    description
    |> plain_text()
    |> String.slice(0, 300)
  end

  # --- Feed Fetching ---

  defp get_feeds(args) do
    args
    |> feed_list()
    |> some_feeds()
  end

  defp some_feeds([]), do: {:error, :no_feeds}
  defp some_feeds(feeds), do: {:ok, feeds}

  defp feed_list(args) do
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
    Enum.map(Resources.list_resources(%{type: "rss_feed", enabled: true}), fn r ->
      {r.name, r.url}
    end)
  end

  defp fetch_feed({name, url}, recv_timeout) do
    case Req.get(url, receive_timeout: recv_timeout, retry: false) do
      {:ok, %{status: 200, body: body}} -> read_feed(name, body)
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec parse_rss(String.t(), binary()) :: [map()]
  def parse_rss(feed_name, xml) when is_binary(xml), do: items_or_none(read_feed(feed_name, xml))

  defp items_or_none({:ok, items}), do: items
  defp items_or_none({:error, _reason}), do: []

  # A body that does not parse is a feed that failed, not a feed with no items.
  #
  # Feed bodies are untrusted, so entity expansion matters here. The xmerl in the
  # OTP this ships with refuses entity declarations outright — measured, not
  # assumed: a DOCTYPE with an internal or external entity exits with
  # :entities_not_allowed whether :dtd is :all, :none, or unset. dtd: :none is
  # passed anyway so the behaviour is stated rather than inherited, and the tests
  # pin it so a future OTP or sweet_xml that relaxes the default is caught here
  # rather than in production.
  defp read_feed(feed_name, xml) when is_binary(xml) do
    items =
      xml
      |> parse(dtd: :none)
      |> xpath(~x"//item"l,
        title: ~x"./title/text()"s,
        link: ~x"./link/text()"s,
        description: ~x"./description/text()"s,
        pub_date: ~x"./pubDate/text()"s
      )
      |> Enum.map(&Map.put(&1, :feed, feed_name))

    {:ok, items}
  rescue
    e ->
      Logger.warning("RSS parse failed for #{feed_name}: #{Exception.message(e)}", skill: :rss)
      {:error, {:unreadable, Exception.message(e)}}
  catch
    :exit, reason ->
      Logger.warning("RSS XML parse exit for #{feed_name}: #{inspect(reason)}", skill: :rss)
      {:error, {:unreadable, reason}}
  end

  defp read_feed(_feed_name, _body), do: {:error, {:unreadable, :not_xml}}

  # --- Dedup ---

  defp already_seen?(item) do
    AlexClaw.Memory.exists?(item.link)
  end

  # --- Scoring (single LLM call with titles only) ---

  @max_items_to_score 20

  defp score_and_filter([], _threshold, _max_items, _llm_opts, _config), do: {:ok, []}

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
      {:ok, []}
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
    count = length(items)

    Logger.info(
      "Scoring #{count} items in single LLM call (interests: #{String.slice(interests, 0, 80)})",
      skill: :rss
    )

    # A list of numbers needs no reasoning; a thinking model spent the whole
    # local timeout on it (run 20, 2026-09-23).
    opts =
      llm_opts
      |> Keyword.put_new(:tier, :light)
      |> Keyword.put(:thinking, false)

    interests
    |> scoring_prompt(items, count)
    |> AlexClaw.LLM.complete(opts)
    |> select_scored(items, threshold, max_items)
  end

  defp scoring_prompt(interests, items, count) do
    numbered =
      items
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {item, i} -> "#{i}. #{item.title || "(no title)"}" end)

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

  defp select_scored({:error, reason}, _items, _threshold, _max_items) do
    Logger.warning("Scoring failed: #{inspect(reason)}", skill: :rss)
    {:error, {:scoring_failed, reason}}
  end

  defp select_scored({:ok, text}, items, threshold, max_items) do
    Logger.info("Scoring response (first 500 chars): #{String.slice(text, 0, 500)}", skill: :rss)

    scores = parse_scores(text)
    keep_scored(Enum.any?(scores, &is_float/1), scores, text, items, {threshold, max_items})
  end

  # A reply with no score in it is not "nothing relevant".
  defp keep_scored(false, _scores, text, _items, _limits),
    do: {:error, {:unreadable_scores, String.slice(text, 0, 200)}}

  defp keep_scored(true, scores, _text, items, {threshold, max_items}) do
    scored =
      items
      |> Enum.with_index()
      |> Enum.map(fn {item, i} -> Map.put(item, :score, Enum.at(scores, i) || 0.0) end)
      |> Enum.sort_by(& &1.score, :desc)

    # Relative selection: take the top N, with the threshold as a floor.
    passed =
      scored
      |> Enum.filter(&(&1.score >= threshold))
      |> Enum.take(max_items)

    Logger.info(
      "Top-#{max_items} (threshold: #{threshold}): scores=#{inspect(Enum.map(scored, & &1.score))}, passed=#{length(passed)}",
      skill: :rss
    )

    {:ok, passed}
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
