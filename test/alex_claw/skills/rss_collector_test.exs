defmodule AlexClaw.Skills.RSSCollectorTest do
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Skills.RSSCollector

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(AlexClaw.Repo, {:shared, self()})
    :ok
  end

  describe "run/1" do
    test "returns ok with no feeds available" do
      result = RSSCollector.run(%{resources: [], config: %{}})
      assert {:ok, "No relevant news items found.", _branch} = result
    end

    test "accepts force flag from config" do
      result = RSSCollector.run(%{resources: [], config: %{"force" => true}})
      assert {:ok, "No relevant news items found.", _branch} = result
    end

    test "accepts threshold from config" do
      result = RSSCollector.run(%{resources: [], config: %{"threshold" => 0.5}})
      assert {:ok, "No relevant news items found.", _branch} = result
    end

    test "fetches and parses RSS feed from bypass" do
      bypass = Bypass.open()

      xml = """
      <?xml version="1.0"?>
      <rss version="2.0">
        <channel>
          <item>
            <title>Test Article</title>
            <link>https://example.com/article-#{System.unique_integer([:positive])}</link>
            <description>Article description</description>
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
        name: "Test Feed",
        type: "rss_feed",
        url: "http://localhost:#{bypass.port}/feed.xml",
        enabled: true
      }

      result = RSSCollector.run(%{
        resources: [resource],
        config: %{"threshold" => 0.0}
      })

      assert {:ok, _, _branch} = result
    end
  end
end
