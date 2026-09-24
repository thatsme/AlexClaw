defmodule AlexClaw.Skills.RssFeedsExplicitTest do
  @moduledoc """
  A feed skill reads the feeds it is given — every enabled feed on the
  instance only when asked to (reports/SECOND_ROUND_SEAMS.md §4; 0.3.53).

  With no resources, `rss_collector` and `rss_fetch` silently read every
  enabled feed on the instance (rss_collector.ex:192–209). Over MCP, which
  always passes `resources: []`, that meant all twelve feeds, tech and
  finance mixed; and a feed removed from one workflow kept appearing wherever
  the fallback applied.

  Now the fallback is opt-in: `"all_feeds": true` in the config. Without it,
  no resources is the "no feeds" failure from 0.3.51. MCP passes the flag
  where it means it.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Skills.{RSSCollector, RssFetch}
  alias AlexClawTest.LLMMock
  alias Ecto.Adapters.SQL.Sandbox

  setup ctx do
    Sandbox.mode(AlexClaw.Repo, {:shared, self()})
    LLMMock.use_mock(ctx)
    LLMMock.answer("0.9")

    bypass = Bypass.open()
    now = Calendar.strftime(DateTime.utc_now(), "%a, %d %b %Y %H:%M:%S +0000")
    unique = System.unique_integer([:positive])

    Bypass.stub(bypass, "GET", "/feed.xml", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/xml")
      |> Plug.Conn.resp(200, """
      <?xml version="1.0"?><rss version="2.0"><channel>
        <item><title>Instance feed item #{unique}</title>
          <link>https://example.com/#{unique}</link><description>d</description>
          <pubDate>#{now}</pubDate></item>
      </channel></rss>
      """)
    end)

    {:ok, _} =
      AlexClaw.Resources.create_resource(%{
        name: "Instance feed #{unique}",
        type: "rss_feed",
        url: "http://localhost:#{bypass.port}/feed.xml",
        enabled: true
      })

    %{unique: unique}
  end

  defp failure?(skill, result) do
    case result do
      {:error, _} -> true
      {:ok, _, branch} -> branch in AlexClaw.Skill.error_routes(skill)
      _ -> false
    end
  end

  for skill <- [RSSCollector, RssFetch] do
    describe "#{inspect(skill)}" do
      test "no resources and no flag: the no-feeds failure, not the instance's feeds" do
        result = unquote(skill).run(%{resources: [], config: %{"force" => true}})
        assert failure?(unquote(skill), result), inspect(result)
      end

      test "all_feeds: true reads every enabled feed", %{unique: unique} do
        result =
          unquote(skill).run(%{
            resources: [],
            config: %{"all_feeds" => true, "force" => true, "threshold" => 0.0}
          })

        assert {:ok, output, _branch} = result
        assert output =~ "Instance feed item #{unique}"
      end
    end
  end
end
