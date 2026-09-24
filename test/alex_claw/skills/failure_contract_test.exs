defmodule AlexClaw.Skills.FailureContractTest do
  @moduledoc """
  A skill never turns its own failure into a success or into "nothing found"
  (reports/SKILL_ERROR_SWALLOWING.md; 0.3.51).

  On 2026-09-23 a news digest's model timed out; `rss_collector` reported
  "No relevant news items found.", the run ended `completed`, and nothing was
  sent. The sweep found the same shape in fifteen skills.

  The contract, one row per skill and dependency failure: the result is
  either `{:error, _}` or `{:ok, _, branch}` where `branch` is one the skill
  declares as an error route (`error_routes/0`, default `[:on_error]`).
  Never a success branch, never an empty branch. The executor fails a run on
  an unrouted error route and marks it `recovered` when one is routed
  (branch_kinds_test.exs), so routing on `on_timeout` or `on_4xx` keeps
  working and nothing slips through.

  A new core skill that talks to anything that can fail gets a row here.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Skills.{
    ApiRequest,
    DiscordNotify,
    GoogleCalendar,
    LlmScore,
    RSSCollector,
    RssFetch,
    Shell,
    TelegramNotify,
    WebFetch
  }

  alias AlexClawTest.LLMMock
  alias Ecto.Adapters.SQL.Sandbox

  setup :use_mock

  defp use_mock(ctx) do
    Sandbox.mode(AlexClaw.Repo, {:shared, self()})
    LLMMock.use_mock(ctx)
  end

  # A failure-shaped result, as the contract defines it. Skill.error_routes/1
  # applies the default ([:on_error]) for a skill that declares none.
  defp failure?(skill, result) do
    case result do
      {:error, _} -> true
      {:ok, _, branch} -> branch in AlexClaw.Skill.error_routes(skill)
      _ -> false
    end
  end

  defp assert_failure(skill, result, what) do
    assert failure?(skill, result),
           "#{inspect(skill)} reported #{what} as #{inspect(result, limit: 5)}"
  end

  # A feed whose items are fresh, so they pass the 48-hour filter and reach
  # the scoring call. (rss_collector_test.exs used March dates: scoring never
  # ran, and the test passed without testing it.)
  defp fresh_feed do
    bypass = Bypass.open()
    now = Calendar.strftime(DateTime.utc_now(), "%a, %d %b %Y %H:%M:%S +0000")

    Bypass.stub(bypass, "GET", "/feed.xml", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/xml")
      |> Plug.Conn.resp(200, """
      <?xml version="1.0"?>
      <rss version="2.0"><channel>
        <item><title>Fresh #{System.unique_integer([:positive])}</title>
          <link>https://example.com/#{System.unique_integer([:positive])}</link>
          <description>d</description><pubDate>#{now}</pubDate></item>
      </channel></rss>
      """)
    end)

    feed("http://localhost:#{bypass.port}/feed.xml")
  end

  defp failing_feed(status) do
    bypass = Bypass.open()
    Bypass.stub(bypass, "GET", "/feed.xml", &Plug.Conn.resp(&1, status, "no"))
    feed("http://localhost:#{bypass.port}/feed.xml")
  end

  defp feed(url), do: %{name: "Feed", type: "rss_feed", url: url, enabled: true}

  defp items, do: Jason.encode!([%{"title" => "A", "link" => "https://e/a"}])

  describe "rss_collector" do
    test "the scoring model times out" do
      LLMMock.fail_with(LLMMock.timeout())
      result = RSSCollector.run(%{resources: [fresh_feed()], config: %{"force" => true}})
      assert_failure(RSSCollector, result, "a scoring timeout")
    end

    test "no model is available" do
      LLMMock.fail_with(LLMMock.unavailable())
      result = RSSCollector.run(%{resources: [fresh_feed()], config: %{"force" => true}})
      assert_failure(RSSCollector, result, "a missing model")
    end

    test "the model's reply has no scores in it" do
      LLMMock.answer("I cannot help with that.")
      result = RSSCollector.run(%{resources: [fresh_feed()], config: %{"force" => true}})
      assert_failure(RSSCollector, result, "an unreadable scoring reply")
    end

    test "every feed fails" do
      result =
        RSSCollector.run(%{resources: [failing_feed(404), failing_feed(500)], config: %{}})

      assert_failure(RSSCollector, result, "every feed failing")
    end

    test "no feeds are configured" do
      result = RSSCollector.run(%{resources: [], config: %{}})
      assert_failure(RSSCollector, result, "having no feeds")
    end

    # Partial failure is not failure — but it is said, not only logged.
    test "one dead feed among live ones is named in the output" do
      LLMMock.answer("0.9")
      dead = failing_feed(404)

      assert {:ok, output, _branch} =
               RSSCollector.run(%{
                 resources: [fresh_feed(), dead],
                 config: %{"force" => true, "threshold" => 0.0}
               })

      assert output =~ dead.url, "the skipped feed is not mentioned: #{output}"
    end
  end

  describe "rss_fetch" do
    test "every feed fails" do
      result = RssFetch.run(%{resources: [failing_feed(500)], config: %{}})
      assert_failure(RssFetch, result, "every feed failing")
    end
  end

  describe "llm_score" do
    test "the model times out" do
      LLMMock.fail_with(LLMMock.timeout())
      assert_failure(LlmScore, LlmScore.run(%{input: items(), config: %{}}), "a timeout")
    end

    test "the reply has no scores in it" do
      LLMMock.answer("I cannot help with that.")
      result = LlmScore.run(%{input: items(), config: %{}})
      assert_failure(LlmScore, result, "an unreadable reply")
    end

    test "the input is not a list of items (e.g. a previous step's error text)" do
      for input <- ["not json", Jason.encode!(%{"a" => 1})] do
        result = LlmScore.run(%{input: input, config: %{}})
        assert_failure(LlmScore, result, "unusable input #{inspect(input)}")
      end
    end
  end

  describe "HTTP skills" do
    setup do
      bypass = Bypass.open()
      %{base: "http://localhost:#{bypass.port}", bypass: bypass}
    end

    test "api_request: a 500", %{base: base, bypass: bypass} do
      Bypass.stub(bypass, "GET", "/x", &Plug.Conn.resp(&1, 500, "boom"))
      result = ApiRequest.run(%{config: %{"url" => base <> "/x"}, input: nil})
      assert_failure(ApiRequest, result, "a 500")
    end

    test "api_request: the server is gone", %{base: base, bypass: bypass} do
      Bypass.down(bypass)
      result = ApiRequest.run(%{config: %{"url" => base <> "/x"}, input: nil})
      assert_failure(ApiRequest, result, "a refused connection")
    end

    test "web_fetch: a 404", %{base: base, bypass: bypass} do
      Bypass.stub(bypass, "GET", "/x", &Plug.Conn.resp(&1, 404, "no"))
      result = WebFetch.run(%{config: %{"url" => base <> "/x"}, input: nil})
      assert_failure(WebFetch, result, "a 404")
    end
  end

  describe "notification skills" do
    test "telegram_notify with no chat configured does not say delivered" do
      insert_setting("telegram.chat_id", "", type: "string", category: "telegram")
      result = TelegramNotify.run(%{input: "hello", config: %{}})
      assert_failure(TelegramNotify, result, "sending to no chat")
    end

    test "discord_notify with no channel configured does not say delivered" do
      insert_setting("discord.channel_id", "", type: "string", category: "discord")
      result = DiscordNotify.run(%{input: "hello", config: %{}})
      assert_failure(DiscordNotify, result, "sending to no channel")
    end
  end

  describe "shell" do
    test "a command that does not exist" do
      insert_setting("shell.enabled", "true", type: "boolean", category: "shell")
      command = "definitely-not-a-command-#{System.unique_integer([:positive])}"
      result = Shell.run(%{config: %{"command" => command}, input: nil})
      assert_failure(Shell, result, "a missing command")
    end
  end

  describe "google_calendar" do
    # The "create" action was advertised and never read: a create step listed
    # events and reported success. Until it is implemented, it is refused.
    test "an unsupported action is refused, not ignored" do
      result =
        GoogleCalendar.run(%{config: %{"action" => "create", "summary" => "x"}, input: nil})

      assert {:error, {:unsupported_action, "create"}} = result
    end

    test "its help no longer offers create" do
      refute GoogleCalendar.config_help() =~ ~r/\bcreate\b/i
      refute inspect(GoogleCalendar.config_scaffold()) =~ ~r/\bcreate\b/i
    end
  end
end
