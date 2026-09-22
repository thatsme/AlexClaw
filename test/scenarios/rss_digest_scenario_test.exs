defmodule AlexClaw.Scenarios.RssDigestScenarioTest do
  @moduledoc """
  The RSS digest scenario in mock mode: the real workflow, skills, router and
  executor, with the external systems replaced at their boundary — a feed
  server, an OpenAI-compatible LLM answering fixed scores, and a recording
  gateway in place of Telegram.

  Both paths are asserted: items that pass reach the user in the digest, and
  when nothing passes nothing is sent.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.{LLM, RecordingGateway}
  alias AlexClaw.Scenarios.RssDigest
  alias AlexClaw.Skills.CircuitBreaker

  @titles [
    "Elixir 1.19 released with faster compilation",
    "Local bakery wins regional award",
    "Weather: rain expected this weekend"
  ]

  setup do
    # Circuit breakers are process-wide; tests elsewhere trip llm_transform's on
    # purpose, and a scenario must start from closed circuits.
    Enum.each(
      ~w(rss_fetch llm_score llm_transform telegram_notify),
      &CircuitBreaker.reset/1
    )

    feed = Bypass.open()
    llm = Bypass.open()
    RecordingGateway.install()

    {:ok, _} =
      LLM.create_provider(%{
        name: "scenario-mock-llm",
        type: "openai_compatible",
        tier: "light",
        model: "mock",
        host: "http://localhost:#{llm.port}",
        enabled: true,
        priority: 1
      })

    Bypass.stub(feed, "GET", "/feed.xml", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/rss+xml")
      |> Plug.Conn.resp(200, rss(@titles))
    end)

    %{feed_url: "http://localhost:#{feed.port}/feed.xml", llm: llm}
  end

  # Scores for the scoring prompt; for the digest prompt, a digest that keeps
  # the titles it was given, as the prompt asks.
  defp answer_llm(llm, scores) do
    Bypass.stub(llm, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      prompt =
        body |> Jason.decode!() |> Map.fetch!("messages") |> List.last() |> Map.fetch!("content")

      content =
        if prompt =~ "news relevance scorer",
          do: scores_in_prompt_order(prompt, scores),
          else:
            @titles |> Enum.filter(&(prompt =~ &1)) |> Enum.map_join("\n", &"- #{&1} — noted.")

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{"choices" => [%{"message" => %{"content" => content}}]})
      )
    end)
  end

  # The prompt lists headlines in the order the feed was read; each is scored by
  # its title, as the fixed scores are given in @titles order.
  defp scores_in_prompt_order(prompt, scores) do
    by_title = Map.new(Enum.zip(@titles, scores))

    ~r/^\d+\. (.+)$/m
    |> Regex.scan(prompt)
    |> Enum.map_join("\n", fn [_, title] -> Map.fetch!(by_title, String.trim(title)) end)
  end

  defp rss(titles) do
    now = Calendar.strftime(DateTime.utc_now(), "%a, %d %b %Y %H:%M:%S +0000")

    items =
      Enum.map_join(Enum.with_index(titles, 1), "\n", fn {title, i} ->
        "<item><title>#{title}</title><link>https://example.com/#{i}</link>" <>
          "<description>About #{title}</description><pubDate>#{now}</pubDate></item>"
      end)

    ~s(<?xml version="1.0"?><rss version="2.0"><channel><title>Mock</title>#{items}</channel></rss>)
  end

  defp run(feed_url, opts),
    do: RssDigest.run([feeds: [{"Mock feed", feed_url}], interests: "programming"] ++ opts)

  test "items that pass reach the user: the digest names them", %{feed_url: url, llm: llm} do
    answer_llm(llm, ["0.9", "0.2", "0.1"])

    report = run(url, expect: :items)

    assert report.verdict == :pass, AlexClaw.Scenarios.format(report)
    assert report.details.fetched == 3
    assert report.details.passed == ["Elixir 1.19 released with faster compilation"]
    assert [message] = RecordingGateway.sent()
    assert message =~ "Elixir 1.19 released with faster compilation"
    refute message =~ "bakery"
  end

  test "when nothing passes, nothing is sent", %{feed_url: url, llm: llm} do
    answer_llm(llm, ["0.1", "0.2", "0.1"])

    report = run(url, expect: :empty)

    assert report.verdict == :pass, AlexClaw.Scenarios.format(report)
    assert report.details.path == ["fetch:on_items", "score:on_empty"]
    assert RecordingGateway.sent() == []
  end

  # The harness itself: an empty digest is not a success.
  test "expecting items, a run where nothing passes fails", %{feed_url: url, llm: llm} do
    answer_llm(llm, ["0.1", "0.1", "0.1"])

    assert {:fail, reason} = run(url, expect: :items).verdict
    assert reason =~ "nothing scored above the threshold"
  end

  test "a digest that drops the titles fails", %{feed_url: url, llm: llm} do
    Bypass.stub(llm, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      prompt =
        body |> Jason.decode!() |> Map.fetch!("messages") |> List.last() |> Map.fetch!("content")

      content =
        if prompt =~ "news relevance scorer",
          do: scores_in_prompt_order(prompt, ["0.9", "0.1", "0.1"]),
          else: "- A new release of a programming language."

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{"choices" => [%{"message" => %{"content" => content}}]})
      )
    end)

    assert {:fail, reason} = run(url, expect: :items).verdict
    assert reason =~ "no scored title appears"
  end

  test "the scenario removes what it built, and keeps the run" do
    before =
      {Repo.aggregate(AlexClaw.Workflows.Workflow, :count),
       Repo.aggregate(AlexClaw.Resources.Resource, :count)}

    llm = Bypass.open()
    feed = Bypass.open()
    Bypass.stub(feed, "GET", "/feed.xml", fn conn -> Plug.Conn.resp(conn, 200, rss(@titles)) end)
    answer_llm(llm, ["0.1", "0.1", "0.1"])
    Repo.update_all(AlexClaw.LLM.Provider, set: [host: "http://localhost:#{llm.port}"])

    report = run("http://localhost:#{feed.port}/feed.xml", expect: :empty)

    assert {Repo.aggregate(AlexClaw.Workflows.Workflow, :count),
            Repo.aggregate(AlexClaw.Resources.Resource, :count)} ==
             before

    assert Repo.get(AlexClaw.Workflows.WorkflowRun, report.details.run_id)
  end
end
