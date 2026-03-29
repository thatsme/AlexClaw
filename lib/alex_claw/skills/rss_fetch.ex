defmodule AlexClaw.Skills.RssFetch do
  @moduledoc """
  Pure RSS fetch skill. Fetches RSS feeds, parses items, deduplicates,
  and returns raw items. No LLM scoring, no notification.

  Use with `llm_score` for relevance filtering:
    rss_fetch → llm_score → llm_transform → telegram_notify
  """
  @behaviour AlexClaw.Skill
  @impl true
  def external, do: true
  @impl true
  def description, do: "Fetches RSS feeds and returns raw items (no LLM scoring)"

  @impl true
  def routes, do: [:on_items, :on_empty, :on_error]

  require Logger
  import SweetXml
  import AlexClaw.Skills.Helpers, only: [parse_int: 2]

  alias AlexClaw.Resources

  @default_max_items 20
  @default_recent_hours 48

  @impl true
  def step_fields, do: [:config]

  @impl true
  def config_hint, do: ~s|{"max_items": 20, "recent_hours": 48} — pure fetch, no scoring|

  @impl true
  def config_scaffold, do: %{"max_items" => 20, "recent_hours" => 48}

  @impl true
  def config_presets do
    %{
      "Recent 24h" => %{"max_items" => 20, "recent_hours" => 24},
      "Recent 48h" => %{"max_items" => 30, "recent_hours" => 48},
      "Force all" => %{"max_items" => 50, "recent_hours" => 168, "force" => true}
    }
  end

  @impl true
  def config_help,
    do:
      "max_items: limit total items. recent_hours: only items newer than this (default 48). force: include already-seen items. Returns raw items — no scoring. Chain with llm_score."

  @impl true
  def run(args) do
    config = args[:config] || %{}
    feeds = get_feeds(args)
    max_items = parse_int(config["max_items"], @default_max_items)
    recent_hours = parse_int(config["recent_hours"], @default_recent_hours)
    fetch_timeout = parse_int(config["fetch_timeout"], 15)
    force = config["force"] == true

    if feeds == [] do
      {:error, :no_feeds}
    else
      recv_timeout = fetch_timeout * 1_000
      task_timeout = recv_timeout + 5_000

      items =
        feeds
        |> Task.async_stream(&fetch_feed(&1, recv_timeout),
          max_concurrency: 5,
          timeout: task_timeout,
          on_timeout: :kill_task
        )
        |> Enum.flat_map(fn
          {:ok, {:ok, items}} -> items
          {:ok, {:error, reason}} ->
            Logger.warning("Feed fetch failed: #{inspect(reason)}", skill: :rss_fetch)
            []
          {:exit, reason} ->
            Logger.warning("Feed fetch crashed: #{inspect(reason)}", skill: :rss_fetch)
            []
        end)

      items =
        if force do
          items
        else
          Enum.reject(items, &already_seen?/1)
        end

      items =
        items
        |> filter_recent(recent_hours)
        |> Enum.take(max_items)

      if items == [] do
        {:ok, "No new RSS items found.", :on_empty}
      else
        output = Jason.encode!(items)
        {:ok, output, :on_items}
      end
    end
  end

  defp get_feeds(args) do
    case args[:resources] do
      resources when is_list(resources) and resources != [] ->
        resources
        |> Enum.filter(fn r -> r.type == "rss_feed" and r.enabled end)
        |> Enum.map(fn r -> {r.name, r.url} end)

      _ ->
        Enum.map(Resources.list_resources(%{type: "rss_feed", enabled: true}), fn r -> {r.name, r.url} end)
    end
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
      Logger.warning("RSS parse failed for #{feed_name}: #{Exception.message(e)}", skill: :rss_fetch)
      []
  catch
    :exit, reason ->
      Logger.warning("RSS XML parse exit for #{feed_name}: #{inspect(reason)}", skill: :rss_fetch)
      []
  end

  defp already_seen?(item) do
    AlexClaw.Memory.exists?(item.link)
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
end
