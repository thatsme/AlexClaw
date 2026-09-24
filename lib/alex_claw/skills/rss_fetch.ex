defmodule AlexClaw.Skills.RssFetch do
  @moduledoc """
  Pure RSS fetch skill. Fetches RSS feeds, parses items, deduplicates,
  and returns raw items. No LLM scoring, no notification.

  Use with `llm_score` for relevance filtering:
    rss_fetch → llm_score → llm_transform → telegram_notify
  """
  @behaviour AlexClaw.Skill
  @impl true
  @spec external() :: boolean()
  def external, do: true
  @impl true
  def description, do: "Fetches RSS feeds and returns raw items (no LLM scoring)"

  @impl true
  @spec routes() :: [atom()]
  def routes, do: [:on_items, :on_empty, :on_error]

  require Logger
  import SweetXml
  import AlexClaw.Skills.Helpers, only: [parse_int: 2]

  alias AlexClaw.Resources

  @default_max_items 20
  @default_recent_hours 48

  @impl true
  @spec step_fields() :: [atom()]
  def step_fields, do: [:config]

  @impl true
  @spec config_hint() :: String.t()
  def config_hint, do: ~s|{"max_items": 20, "recent_hours": 48} — pure fetch, no scoring|

  @impl true
  @spec config_scaffold() :: map()
  def config_scaffold, do: %{"max_items" => 20, "recent_hours" => 48}

  @impl true
  @spec config_presets() :: %{String.t() => map()}
  def config_presets do
    %{
      "Recent 24h" => %{"max_items" => 20, "recent_hours" => 24},
      "Recent 48h" => %{"max_items" => 30, "recent_hours" => 48},
      "Force all" => %{"max_items" => 50, "recent_hours" => 168, "force" => true}
    }
  end

  @impl true
  @spec config_help() :: String.t()
  def config_help,
    do:
      "max_items: limit total items. recent_hours: only items newer than this (default 48). force: include already-seen items. Returns raw items — no scoring. Chain with llm_score."

  @impl true
  @spec run(map()) :: {:ok, any(), atom()} | {:error, any()}
  def run(args) do
    config = args[:config] || %{}
    max_items = parse_int(config["max_items"], @default_max_items)
    recent_hours = parse_int(config["recent_hours"], @default_recent_hours)
    fetch_timeout = parse_int(config["fetch_timeout"], 15)
    force = config["force"] == true

    with {:ok, feeds} <- some_feeds(get_feeds(args)),
         {:ok, items} <- fetch_all(feeds, fetch_timeout * 1_000) do
      items
      |> reject_seen(force)
      |> filter_recent(recent_hours)
      |> Enum.take(max_items)
      |> result()
    end
  end

  defp some_feeds([]), do: {:error, :no_feeds}
  defp some_feeds(feeds), do: {:ok, feeds}

  # A feed that cannot be fetched or read is skipped; when every feed fails,
  # the step fails rather than reporting nothing new.
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

  defp feed_result({{:ok, {:ok, items}}, _feed}), do: {:ok, items}

  defp feed_result({{:ok, {:error, reason}}, {_name, url}}) do
    Logger.warning("Feed #{url} failed: #{inspect(reason)}", skill: :rss_fetch)
    {:error, url}
  end

  defp feed_result({{:exit, reason}, {_name, url}}) do
    Logger.warning("Feed #{url} crashed: #{inspect(reason)}", skill: :rss_fetch)
    {:error, url}
  end

  defp fetched({[], dead}), do: {:error, {:all_feeds_failed, Enum.map(dead, &elem(&1, 1))}}
  defp fetched({live, _dead}), do: {:ok, Enum.flat_map(live, &elem(&1, 1))}

  defp reject_seen(items, true), do: items
  defp reject_seen(items, false), do: Enum.reject(items, &already_seen?/1)

  defp result([]), do: {:ok, "No new RSS items found.", :on_empty}
  defp result(items), do: {:ok, Jason.encode!(items), :on_items}

  defp get_feeds(args) do
    case args[:resources] do
      resources when is_list(resources) and resources != [] ->
        resources
        |> Enum.filter(fn r -> r.type == "rss_feed" and r.enabled end)
        |> Enum.map(fn r -> {r.name, r.url} end)

      _ ->
        Enum.map(Resources.list_resources(%{type: "rss_feed", enabled: true}), fn r ->
          {r.name, r.url}
        end)
    end
  end

  defp fetch_feed({name, url}, recv_timeout) do
    case Req.get(url, receive_timeout: recv_timeout, retry: false) do
      {:ok, %{status: 200, body: body}} -> parse_rss(name, body)
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # A body that does not parse is a feed that failed, not a feed with no items.
  defp parse_rss(feed_name, xml) when is_binary(xml) do
    items =
      xml
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
      Logger.warning("RSS parse failed for #{feed_name}: #{Exception.message(e)}",
        skill: :rss_fetch
      )

      {:error, {:unreadable, Exception.message(e)}}
  catch
    :exit, reason ->
      Logger.warning("RSS XML parse exit for #{feed_name}: #{inspect(reason)}", skill: :rss_fetch)
      {:error, {:unreadable, reason}}
  end

  defp parse_rss(_feed_name, _body), do: {:error, {:unreadable, :not_xml}}

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
