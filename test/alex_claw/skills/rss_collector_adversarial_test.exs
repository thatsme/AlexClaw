defmodule AlexClaw.Skills.RSSCollectorAdversarialTest do
  use AlexClaw.DataCase, async: false

  alias AlexClaw.Skills.RSSCollector

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(AlexClaw.Repo, {:shared, self()})
    :ok
  end

  describe "malformed RSS feeds" do
    test "handles non-XML response gracefully" do
      bypass = Bypass.open()

      Bypass.expect(bypass, "GET", "/feed.xml", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.resp(200, "This is not XML at all")
      end)

      resource = %{
        name: "Bad Feed",
        type: "rss_feed",
        url: "http://localhost:#{bypass.port}/feed.xml",
        enabled: true
      }

      result = RSSCollector.run(%{resources: [resource], config: %{"threshold" => 0.0}})
      assert match?({:ok, _}, result)
    end

    test "handles empty XML response gracefully" do
      bypass = Bypass.open()

      Bypass.expect(bypass, "GET", "/feed.xml", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.resp(200, "")
      end)

      resource = %{
        name: "Empty Feed",
        type: "rss_feed",
        url: "http://localhost:#{bypass.port}/feed.xml",
        enabled: true
      }

      result = RSSCollector.run(%{resources: [resource], config: %{"threshold" => 0.0}})
      assert match?({:ok, _}, result)
    end

    test "handles XML with missing item fields" do
      bypass = Bypass.open()

      xml = """
      <?xml version="1.0"?>
      <rss version="2.0">
        <channel>
          <item>
            <title>No Link Article</title>
          </item>
          <item>
            <link>https://example.com/no-title</link>
          </item>
          <item></item>
        </channel>
      </rss>
      """

      Bypass.expect(bypass, "GET", "/feed.xml", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.resp(200, xml)
      end)

      resource = %{
        name: "Partial Feed",
        type: "rss_feed",
        url: "http://localhost:#{bypass.port}/feed.xml",
        enabled: true
      }

      result = RSSCollector.run(%{resources: [resource], config: %{"threshold" => 0.0}})
      assert match?({:ok, _}, result)
    end

    test "handles XML with HTML entities in title" do
      bypass = Bypass.open()

      xml = """
      <?xml version="1.0"?>
      <rss version="2.0">
        <channel>
          <item>
            <title>&lt;script&gt;alert('xss')&lt;/script&gt; &amp; more</title>
            <link>https://example.com/xss-#{System.unique_integer([:positive])}</link>
            <description>Test &amp; description</description>
            <pubDate>Thu, 13 Mar 2026 07:00:00 +0000</pubDate>
          </item>
        </channel>
      </rss>
      """

      Bypass.expect(bypass, "GET", "/feed.xml", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.resp(200, xml)
      end)

      resource = %{
        name: "XSS Feed",
        type: "rss_feed",
        url: "http://localhost:#{bypass.port}/feed.xml",
        enabled: true
      }

      result = RSSCollector.run(%{resources: [resource], config: %{"threshold" => 0.0}})
      assert match?({:ok, _}, result)
    end

    test "handles feed HTTP error (404)" do
      bypass = Bypass.open()

      Bypass.expect(bypass, "GET", "/feed.xml", fn conn ->
        Plug.Conn.resp(conn, 404, "Not Found")
      end)

      resource = %{
        name: "Missing Feed",
        type: "rss_feed",
        url: "http://localhost:#{bypass.port}/feed.xml",
        enabled: true
      }

      result = RSSCollector.run(%{resources: [resource], config: %{"threshold" => 0.0}})
      assert {:ok, "No relevant news items found."} = result
    end

    @tag :skip
    test "handles feed connection timeout" do
    end
  end

  describe "resource filtering" do
    test "skips disabled resources" do
      resource = %{
        name: "Disabled",
        type: "rss_feed",
        url: "http://localhost/disabled",
        enabled: false
      }

      result = RSSCollector.run(%{resources: [resource], config: %{"threshold" => 0.0}})
      assert {:ok, "No relevant news items found."} = result
    end

    test "skips non-rss_feed resources" do
      resource = %{
        name: "API Resource",
        type: "api",
        url: "http://localhost/api",
        enabled: true
      }

      result = RSSCollector.run(%{resources: [resource], config: %{"threshold" => 0.0}})
      assert {:ok, "No relevant news items found."} = result
    end
  end

  describe "config parsing" do
    test "threshold as string" do
      result = RSSCollector.run(%{resources: [], config: %{"threshold" => "0.5"}})
      assert {:ok, _} = result
    end

    test "threshold as invalid string" do
      result = RSSCollector.run(%{resources: [], config: %{"threshold" => "not_a_number"}})
      assert {:ok, _} = result
    end

    test "force as boolean" do
      result = RSSCollector.run(%{resources: [], config: %{"force" => true}})
      assert {:ok, _} = result
    end

    test "completely nil config" do
      result = RSSCollector.run(%{resources: []})
      assert {:ok, _} = result
    end
  end
end
