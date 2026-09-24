defmodule AlexClaw.Skills.RSSCollectorAdversarialTest do
  @moduledoc """
  rss_collector against broken feeds and bad config: it never crashes, and it
  never reports a failure as "nothing found" (failure_contract_test.exs).

  Rewritten for 0.3.51. The old version asserted that a 404, a non-XML body
  and "no usable feeds" all returned "No relevant news items found." — the
  swallowing the contract forbids — and held an empty test tagged :skip for
  the connection timeout. The timeout is covered for the scoring call in the
  failure contract; a feed that never answers is covered by "every feed
  fails" there as a refused connection.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :adversarial

  alias AlexClaw.Skills.RSSCollector
  alias AlexClawTest.LLMMock
  alias Ecto.Adapters.SQL.Sandbox

  setup ctx do
    Sandbox.mode(AlexClaw.Repo, {:shared, self()})
    LLMMock.use_mock(ctx)
  end

  defp failure?(result) do
    case result do
      {:error, _} -> true
      {:ok, _, branch} -> branch in AlexClaw.Skill.error_routes(RSSCollector)
      _ -> false
    end
  end

  defp serving(status, content_type, body) do
    bypass = Bypass.open()

    Bypass.stub(bypass, "GET", "/feed.xml", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type(content_type)
      |> Plug.Conn.resp(status, body)
    end)

    %{
      name: "Feed",
      type: "rss_feed",
      url: "http://localhost:#{bypass.port}/feed.xml",
      enabled: true
    }
  end

  defp run(resources, config \\ %{"threshold" => 0.0}),
    do: RSSCollector.run(%{resources: resources, config: config})

  describe "a feed that cannot be read is a failure, not an empty result" do
    test "a body that is not XML" do
      assert failure?(run([serving(200, "text/plain", "This is not XML at all")]))
    end

    test "an empty body" do
      assert failure?(run([serving(200, "application/xml", "")]))
    end

    test "a 404" do
      assert failure?(run([serving(404, "text/plain", "Not Found")]))
    end
  end

  describe "a feed that parses is not a failure" do
    test "items with missing fields are skipped, and nothing breaks" do
      xml = """
      <?xml version="1.0"?>
      <rss version="2.0"><channel>
        <item><title>No Link Article</title></item>
        <item><link>https://example.com/no-title</link></item>
        <item></item>
      </channel></rss>
      """

      result = run([serving(200, "application/xml", xml)])
      assert match?({:ok, _, _}, result), inspect(result)
    end

    test "HTML entities in a title do not break parsing" do
      xml = """
      <?xml version="1.0"?>
      <rss version="2.0"><channel><item>
        <title>&lt;script&gt;alert('xss')&lt;/script&gt; &amp; more</title>
        <link>https://example.com/xss-#{System.unique_integer([:positive])}</link>
        <description>Test &amp; description</description>
        <pubDate>Thu, 13 Mar 2026 07:00:00 +0000</pubDate>
      </item></channel></rss>
      """

      result = run([serving(200, "application/xml", xml)])
      assert match?({:ok, _, _}, result), inspect(result)
    end
  end

  describe "no usable feed is a failure" do
    test "only disabled resources" do
      disabled = %{name: "Off", type: "rss_feed", url: "http://localhost/off", enabled: false}
      assert failure?(run([disabled]))
    end

    test "only resources that are not feeds" do
      api = %{name: "API", type: "api", url: "http://localhost/api", enabled: true}
      assert failure?(run([api]))
    end
  end

  # Bad config must not crash the skill. With no feeds the result is the
  # "no feeds" failure; the point is that it is a result, not an exception.
  describe "config parsing" do
    test "threshold as a string, an invalid string, force as a boolean, nil config" do
      for config <- [
            %{"threshold" => "0.5"},
            %{"threshold" => "not_a_number"},
            %{"force" => true},
            nil
          ] do
        result = RSSCollector.run(%{resources: [], config: config})
        assert failure?(result), "config #{inspect(config)} gave #{inspect(result)}"
      end
    end
  end
end
