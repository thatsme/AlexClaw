defmodule AlexClaw.Skills.Dynamic.RssV2 do
  @moduledoc """
  Dynamic RSS collector with full article fetching and configurable timeouts.
  Fetches RSS feeds, scores relevance, then fetches full article content from
  each link before storing to memory. Built entirely on SkillAPI.
  """
  @behaviour AlexClaw.Skill

  import SweetXml
  alias AlexClaw.Skills.SkillAPI

  @max_items_to_score 20

  @max_article_chars 4000

  @impl true
  def version, do: "2.0.0"

  @impl true
  def permissions, do: [:llm, :web_read, :telegram_send, :memory_read, :memory_write, :config_read, :resources_read]

  @impl true
  def description, do: "RSS collector v2 — with full article fetch and configurable timeouts"

  @impl true
  def run(args) do
    config = args[:config] || %{}
    feeds = get_feeds(args)
    threshold = to_float(config["threshold"], 0.7)
    max_items = to_int(config["max_items"], 5)
    fetch_timeout = to_int(config["fetch_timeout"], config_get("skills.rss.fetch_timeout", 15))
    fetch_articles = config["fetch_articles"] != false
    force = Map.get(args, :force, false) || config["force"] == true

    llm_opts = build_llm_opts(args)
    recv_timeout = fetch_timeout * 1_000
    task_timeout = recv_timeout + 5_000

    fetched =
      feeds
      |> Task.async_stream(&fetch_feed(&1, recv_timeout), max_concurrency: 5, timeout: task_timeout, on_timeout: :kill_task)
      |> Enum.flat_map(fn
        {:ok, {:ok, items}} -> items
        _ -> []
      end)

    items =
      if force do
        fetched
      else
        Enum.reject(fetched, &seen?/1)
      end

    results = score_and_filter(items, threshold, max_items, llm_opts, config)

    # Fetch full article content for each result
    results =
      if fetch_articles do
        results
        |> Task.async_stream(&fetch_article(&1, recv_timeout), max_concurrency: 3, timeout: task_timeout, on_timeout: :kill_task)
        |> Enum.map(fn
          {:ok, item} -> item
          {:exit, _} -> nil
        end)
        |> Enum.reject(&is_nil/1)
      else
        results
      end

    Enum.each(results, fn item ->
      store_and_notify(item)
      Process.sleep(1_000)
    end)

    summary =
      results
      |> Enum.map_join("\n\n", fn item ->
        article = Map.get(item, :article, "")
        preview = if article != "", do: "\n#{String.slice(article, 0, 500)}", else: ""
        "**#{item.feed}**: #{item.title}#{preview}\n#{item.link}"
      end)

    {:ok, if(summary == "", do: "No relevant news items found.", else: summary)}
  end

  # --- Feeds ---

  defp get_feeds(%{resources: resources}) when is_list(resources) and resources != [] do
    resources
    |> Enum.filter(fn r -> r.type == "rss_feed" and r.enabled end)
    |> Enum.map(fn r -> {r.name, r.url} end)
  end

  defp get_feeds(_args) do
    case SkillAPI.list_resources(__MODULE__, %{type: "rss_feed", enabled: true}) do
      {:ok, resources} -> Enum.map(resources, fn r -> {r.name, r.url} end)
      _ -> []
    end
  end

  defp fetch_feed({name, url}, recv_timeout) do
    case SkillAPI.http_get(__MODULE__, url, receive_timeout: recv_timeout, retry: false) do
      {:ok, %{status: 200, body: body}} -> {:ok, parse_rss(name, body)}
      {:ok, %{status: status}} -> {:error, {:http, status, url}}
      {:error, reason} -> {:error, {name, reason}}
    end
  end

  defp fetch_article(item, recv_timeout) do
    case SkillAPI.http_get(__MODULE__, item.link, receive_timeout: recv_timeout, retry: false) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        article = body |> strip_html() |> String.slice(0, @max_article_chars)
        Map.put(item, :article, article)

      _ ->
        Map.put(item, :article, "")
    end
  end

  defp strip_html(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("article, main, .content, .entry-content, body")
    |> List.first()
    |> case do
      nil -> Floki.text(Floki.parse_document!(html))
      node -> Floki.text(node)
    end
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  rescue
    _ -> Regex.replace(~r/<[^>]+>/, html, " ") |> String.replace(~r/\s+/, " ") |> String.trim()
  end

  defp parse_rss(feed_name, xml) when is_binary(xml) do
    xml
    |> xpath(~x"//item"l,
      title: ~x"./title/text()"s,
      link: ~x"./link/text()"s,
      description: ~x"./description/text()"s,
      pub_date: ~x"./pubDate/text()"s,
      dc_date: ~x"./dc:date/text()"s
    )
    |> Enum.map(fn item ->
      # Use dc:date as fallback when pubDate is empty (RSS 1.0 / RDF feeds like NIST NVD)
      pub_date = if item.pub_date == "", do: item.dc_date, else: item.pub_date
      item |> Map.put(:pub_date, pub_date) |> Map.delete(:dc_date) |> Map.put(:feed, feed_name)
    end)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  # --- Dedup ---

  defp seen?(item) do
    case SkillAPI.memory_exists?(__MODULE__, item.link) do
      {:ok, true} -> true
      _ -> false
    end
  end

  # --- Scoring ---

  defp score_and_filter([], _threshold, _max_items, _llm_opts, _config), do: []

  defp score_and_filter(items, threshold, max_items, llm_opts, config) do
    interests = config["interests"] || "general news, technology, finance, world events"
    items = items |> filter_recent(48) |> Enum.take(@max_items_to_score)
    if items == [], do: [], else: score_batch(items, interests, threshold, max_items, llm_opts)
  end

  defp score_batch(items, interests, threshold, max_items, llm_opts) do
    count = length(items)

    numbered =
      items
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {item, i} -> "#{i}. #{item.title || "(no title)"}" end)

    prompt = """
    You are a news relevance scorer. Rate each headline below from 0.0 (irrelevant) to 1.0 (highly relevant).

    Topics of interest: #{interests}

    Headlines:
    #{numbered}

    Rules:
    - Reply with exactly #{count} lines, one per headline, in the same order.
    - Each line must contain ONLY a decimal number (e.g. 0.8). No text, no numbering, no explanation.
    - Spread your scores: use the full 0.0-1.0 range.
    """

    case SkillAPI.llm_complete(__MODULE__, prompt, llm_opts ++ [tier: :light]) do
      {:ok, text} ->
        scores = parse_scores(text)

        items
        |> Enum.with_index()
        |> Enum.map(fn {item, i} -> Map.put(item, :score, Enum.at(scores, i, 0.0)) end)
        |> Enum.sort_by(& &1.score, :desc)
        |> Enum.filter(& &1.score >= threshold)
        |> Enum.take(max_items)

      {:error, _} ->
        []
    end
  end

  defp parse_scores(text) do
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
    months = %{
      "Jan" => 1, "Feb" => 2, "Mar" => 3, "Apr" => 4, "May" => 5, "Jun" => 6,
      "Jul" => 7, "Aug" => 8, "Sep" => 9, "Oct" => 10, "Nov" => 11, "Dec" => 12
    }

    case Regex.run(~r/(\d{1,2})\s+(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+(\d{4})\s+(\d{2}):(\d{2})/, date_str) do
      [_, day, month, year, hour, min] ->
        with month_num when is_integer(month_num) <- months[month],
             {:ok, ndt} <- NaiveDateTime.new(
               to_int(year, 0), month_num, to_int(day, 0),
               to_int(hour, 0), to_int(min, 0), 0
             ) do
          {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  # --- Store & Notify ---

  defp store_and_notify(item) do
    article = Map.get(item, :article, "")

    content =
      if article != "" do
        "#{item.title}\n\n#{article}"
      else
        "#{item.title}\n#{item.description}"
      end

    SkillAPI.memory_store(__MODULE__, :news_item, content,
      source: item.link,
      metadata: %{feed: item.feed, score: item.score, has_article: article != ""}
    )

    title = String.replace(item.title || "", ~r/[*_`\[\]]/, "")
    SkillAPI.send_telegram(__MODULE__, "*#{item.feed}*\n#{title}\n#{item.link}")
  end

  # --- Helpers ---

  defp build_llm_opts(%{llm_provider: p}) when p not in [nil, "", "auto"], do: [provider: p]
  defp build_llm_opts(_), do: []

  defp config_get(key, default) do
    case SkillAPI.config_get(__MODULE__, key, default) do
      {:ok, value} when not is_nil(value) -> value
      _ -> default
    end
  end

  defp to_int(nil, default), do: default
  defp to_int(val, _) when is_integer(val), do: val
  defp to_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> default
    end
  end
  defp to_int(_, default), do: default

  defp to_float(nil, default), do: default
  defp to_float(val, _) when is_float(val), do: val
  defp to_float(val, _) when is_integer(val), do: val / 1.0
  defp to_float(val, default) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> f
      :error -> default
    end
  end
  defp to_float(_, default), do: default
end
