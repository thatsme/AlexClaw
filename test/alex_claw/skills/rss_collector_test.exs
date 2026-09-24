defmodule AlexClaw.Skills.RSSCollectorTest do
  @moduledoc """
  rss_collector: fetch feeds, keep recent items, score them with the model.

  The old tests asserted "No relevant news items found." for having no feeds
  — the swallowed result the failure contract now forbids
  (failure_contract_test.exs covers every failure). And the feed test used
  items dated March 2026, older than the 48-hour filter: scoring never ran,
  so the one path that failed in production was never exercised. These use
  fresh items and a mocked model, so scoring runs.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Skills.RSSCollector
  alias AlexClawTest.LLMMock
  alias Ecto.Adapters.SQL.Sandbox

  setup ctx do
    Sandbox.mode(AlexClaw.Repo, {:shared, self()})
    LLMMock.use_mock(ctx)
  end

  defp feed_with(titles) do
    bypass = Bypass.open()
    now = Calendar.strftime(DateTime.utc_now(), "%a, %d %b %Y %H:%M:%S +0000")

    items =
      Enum.map_join(titles, "\n", fn title ->
        """
        <item><title>#{title}</title>
          <link>https://example.com/#{System.unique_integer([:positive])}</link>
          <description>d</description><pubDate>#{now}</pubDate></item>
        """
      end)

    Bypass.stub(bypass, "GET", "/feed.xml", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/xml")
      |> Plug.Conn.resp(
        200,
        ~s(<?xml version="1.0"?><rss version="2.0"><channel>#{items}</channel></rss>)
      )
    end)

    %{
      name: "Feed",
      type: "rss_feed",
      url: "http://localhost:#{bypass.port}/feed.xml",
      enabled: true
    }
  end

  test "fresh items reach the model, and those it scores above the threshold are kept" do
    unique = System.unique_integer([:positive])
    LLMMock.answer("0.9\n0.1")

    assert {:ok, output, branch} =
             RSSCollector.run(%{
               resources: [feed_with(["Kept #{unique}", "Dropped #{unique}"])],
               config: %{"force" => true, "threshold" => 0.5}
             })

    refute branch in AlexClaw.Skill.empty_routes(RSSCollector)
    assert output =~ "Kept #{unique}"
    refute output =~ "Dropped #{unique}"
  end

  test "items the model scores below the threshold are an empty result, not a failure" do
    LLMMock.answer("0.1")

    assert {:ok, _output, branch} =
             RSSCollector.run(%{
               resources: [feed_with(["Low #{System.unique_integer([:positive])}"])],
               config: %{"force" => true, "threshold" => 0.5}
             })

    assert branch in AlexClaw.Skill.empty_routes(RSSCollector)
  end

  # The run-20 case: the scoring call must not think through a list of titles.
  test "the scoring call asks the model not to think" do
    test_pid = self()

    Mox.stub(AlexClaw.LLM.Mock, :complete, fn _prompt, opts ->
      send(test_pid, {:opts, opts})
      {:ok, "0.9"}
    end)

    RSSCollector.run(%{
      resources: [feed_with(["Any #{System.unique_integer([:positive])}"])],
      config: %{"force" => true, "threshold" => 0.0}
    })

    assert_receive {:opts, opts}
    assert opts[:thinking] == false
  end
end
