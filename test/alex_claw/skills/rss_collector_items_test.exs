defmodule AlexClaw.Skills.RSSCollectorItemsTest do
  @moduledoc """
  rss_collector hands on structured items, not HTML-laden text
  (reports/DIGEST_LINKS_FACTS.md; 0.3.52).

  It emitted one text block per item, with the first 300 characters of the
  raw description — HTML included. The executor passes every result through
  ContentSanitizer, which read the whole output as one HTML document: the
  item structure was flattened, and a description cut inside a link tag
  swallowed the next item, title and link, up to the next quote. In run 30
  the summariser never saw one item's title; a reproduction lost a whole
  item.

  Now the output is JSON, like rss_fetch's:
      {"items": [{"feed", "title", "summary", "link"}], "skipped": [{"feed", "url"}]}
  - `summary` is plain text: the description's HTML is removed BEFORE it is
    shortened (≤ 300 characters), so no cut can land inside a tag;
  - `link` is the item's own link, untouched;
  - `skipped` names the feeds that could not be read (the partial-failure
    note from 0.3.51, now a field);
  - after the executor's sanitizer, every item is still there, with its own
    title and link.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.ContentSanitizer
  alias AlexClaw.Skills.RSSCollector
  alias AlexClawTest.LLMMock
  alias Ecto.Adapters.SQL.Sandbox

  setup ctx do
    Sandbox.mode(AlexClaw.Repo, {:shared, self()})
    LLMMock.use_mock(ctx)
  end

  # Hacker-News-shaped descriptions: HTML, a link near the 300-character mark.
  defp description(n) do
    String.duplicate("Words about item #{n}. ", 12) <>
      ~s(<p>Comments: <a href="https://news.example.com/item?id=#{n}">discuss #{n}</a></p>)
  end

  defp feed(count) do
    bypass = Bypass.open()
    now = Calendar.strftime(DateTime.utc_now(), "%a, %d %b %Y %H:%M:%S +0000")
    unique = System.unique_integer([:positive])

    items =
      for n <- 1..count do
        """
        <item><title>Title #{n} #{unique}</title>
          <link>https://example.com/#{unique}/#{n}</link>
          <description><![CDATA[#{description(n)}]]></description>
          <pubDate>#{now}</pubDate></item>
        """
      end

    Bypass.stub(bypass, "GET", "/feed.xml", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/xml")
      |> Plug.Conn.resp(
        200,
        ~s(<?xml version="1.0"?><rss version="2.0"><channel>#{Enum.join(items)}</channel></rss>)
      )
    end)

    {%{
       name: "HN-like",
       type: "rss_feed",
       url: "http://localhost:#{bypass.port}/feed.xml",
       enabled: true
     }, unique}
  end

  defp collect(resources, count) do
    LLMMock.answer(Enum.map_join(1..count, "\n", fn _ -> "0.9" end))

    {:ok, output, _branch} =
      RSSCollector.run(%{resources: resources, config: %{"force" => true, "threshold" => 0.5}})

    output
  end

  test "the output is JSON items with feed, title, summary and link" do
    {feed, unique} = feed(3)
    %{"items" => items} = feed |> List.wrap() |> collect(3) |> Jason.decode!()

    assert length(items) == 3

    for item <- items do
      assert Map.keys(item) |> Enum.sort() == ~w(feed link summary title)
      assert item["link"] =~ "https://example.com/#{unique}/"
      assert item["title"] =~ "#{unique}"
    end
  end

  test "summaries are plain text, at most 300 characters, never cut inside a tag" do
    {feed, _unique} = feed(3)
    %{"items" => items} = feed |> List.wrap() |> collect(3) |> Jason.decode!()

    for %{"summary" => summary} <- items do
      assert String.length(summary) <= 300
      refute summary =~ "<", "HTML left in a summary: #{summary}"
      refute summary =~ "href", "a tag fragment left in a summary: #{summary}"
    end
  end

  test "every item survives the executor's sanitizer, with its own title and link" do
    {feed, unique} = feed(4)
    output = feed |> List.wrap() |> collect(4)

    sanitized = ContentSanitizer.sanitize(output)
    %{"items" => items} = Jason.decode!(sanitized)

    assert length(items) == 4

    for n <- 1..4 do
      assert Enum.any?(items, fn item ->
               item["title"] == "Title #{n} #{unique}" and
                 item["link"] == "https://example.com/#{unique}/#{n}"
             end),
             "item #{n} lost its title or link after sanitising"
    end
  end

  test "a feed that could not be read is named in skipped" do
    {feed, _unique} = feed(1)
    dead = Bypass.open()
    Bypass.stub(dead, "GET", "/feed.xml", &Plug.Conn.resp(&1, 404, "no"))
    dead_url = "http://localhost:#{dead.port}/feed.xml"

    output =
      collect([feed, %{name: "Dead", type: "rss_feed", url: dead_url, enabled: true}], 1)

    assert %{"skipped" => [%{"feed" => "Dead", "url" => ^dead_url}]} = Jason.decode!(output)
  end
end
