defmodule AlexClaw.Scenarios.RssDigest do
  @moduledoc """
  RSS digest: feeds → LLM scoring → digest → a message on the gateway.

  Builds `rss_fetch → llm_score → llm_transform → telegram_notify` over the
  given feeds, runs it once, and judges the run by what the user receives:

    * `expect: :items` (the default) passes only when at least one item scored
      above the threshold and the title of one of them is in the delivered
      message. An empty digest is a failure, not a quiet success.
    * `expect: :empty` passes only when nothing scored above the threshold and
      no message was delivered.

  Options: `:feeds` (`[{name, url}]`), `:interests`, `:threshold`, `:expect`.
  The defaults are programming feeds with programming interests, so a real
  match is expected.
  """

  import Ecto.Query

  alias AlexClaw.Repo
  alias AlexClaw.Resources.Resource
  alias AlexClaw.Workflows
  alias AlexClaw.Workflows.Executor

  @default_feeds [
    {"Hacker News", "https://hnrss.org/frontpage"},
    {"Lobsters", "https://lobste.rs/rss"}
  ]
  @default_interests "programming, software engineering, programming languages, open source, developer tools, AI"

  # The digest must keep titles verbatim, or "the title is in the message"
  # could not be checked.
  @digest_prompt """
  Write a short digest of these news items for a chat message. One bullet per
  item: the item's title copied exactly as given, then " — " and one sentence.

  {input}
  """

  @doc "Run the scenario; see the module doc for options."
  @spec run(keyword()) :: AlexClaw.Scenarios.report()
  def run(opts \\ []) do
    feeds = Keyword.get(opts, :feeds, @default_feeds)
    expect = Keyword.get(opts, :expect, :items)
    threshold = Keyword.get(opts, :threshold, 0.5)
    interests = Keyword.get(opts, :interests, @default_interests)

    {workflow, created} = build(feeds, interests, threshold)

    try do
      {status, run} = workflow.id |> Executor.run() |> run_outcome()
      details = details(run, status)
      %{scenario: :rss_digest, verdict: judge(expect, details), details: details}
    after
      cleanup(workflow, created)
    end
  end

  # --- Building what a user builds ---

  defp build(feeds, interests, threshold) do
    {:ok, workflow} =
      Workflows.create_workflow(%{
        name: "scenario: rss_digest #{System.system_time(:second)}",
        enabled: true
      })

    created =
      for {name, url} <- feeds, reduce: [] do
        acc ->
          {resource, new?} = feed(name, url)
          {:ok, _} = Workflows.assign_resource(workflow, resource.id)
          if new?, do: [resource | acc], else: acc
      end

    steps = [
      {"fetch", "rss_fetch",
       %{config: %{"max_items" => 15, "recent_hours" => 168, "force" => true}}},
      {"score", "llm_score",
       %{config: %{"interests" => interests, "threshold" => threshold, "max_items" => 3}}},
      {"digest", "llm_transform", %{prompt_template: @digest_prompt}},
      {"send", "telegram_notify", %{config: %{}}}
    ]

    steps
    |> Enum.with_index(1)
    |> Enum.each(fn {{name, skill, attrs}, position} ->
      {:ok, _} =
        Workflows.add_step(
          workflow,
          Map.merge(%{name: name, skill: skill, position: position}, attrs)
        )
    end)

    {Workflows.get_workflow!(workflow.id), created}
  end

  defp feed(name, url) do
    case Repo.one(from(r in Resource, where: r.url == ^url and r.type == "rss_feed", limit: 1)) do
      nil ->
        {:ok, resource} =
          AlexClaw.Resources.create_resource(%{
            name: "scenario: #{name}",
            type: "rss_feed",
            url: url,
            enabled: true
          })

        {resource, true}

      resource ->
        {resource, false}
    end
  end

  defp cleanup(workflow, created) do
    Workflows.delete_workflow(workflow)
    Enum.each(created, &Repo.delete/1)
  end

  # --- Judging what the user receives ---

  defp run_outcome({:ok, run}), do: {"completed", run}
  defp run_outcome({:error, %{status: status} = run}), do: {status, run}
  defp run_outcome({:error, reason}), do: {"not started: #{inspect(reason)}", nil}

  defp details(nil, status), do: %{status: status}

  defp details(run, status) do
    results = normalize(run.step_results || %{})
    score = step(results, "score")
    send = step(results, "send")

    %{
      run_id: run.id,
      status: status,
      error: run.error,
      path:
        results
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {_, s} -> "#{s["name"]}:#{s["branch"]}" end),
      fetched: count_items(step(results, "fetch")["output"]),
      passed: passed_titles(score),
      message: send && send["output"]
    }
  end

  defp normalize(results), do: Map.new(results, fn {k, v} -> {to_string(k), stringify(v)} end)
  defp stringify(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp step(results, name),
    do: Enum.find_value(results, fn {_, s} -> if s["name"] == name, do: s end)

  defp count_items(output) when is_binary(output) do
    case Jason.decode(output) do
      {:ok, list} when is_list(list) -> length(list)
      _ -> 0
    end
  end

  defp count_items(_), do: 0

  defp passed_titles(%{"branch" => "on_items", "output" => output}) do
    output |> Jason.decode!() |> Enum.map(& &1["title"])
  end

  defp passed_titles(_), do: []

  defp judge(:items, %{status: "completed", passed: [_ | _] = titles, message: message})
       when is_binary(message) do
    if Enum.any?(titles, &title_in?(&1, message)),
      do: :pass,
      else: {:fail, "no scored title appears in the delivered message"}
  end

  defp judge(:items, %{status: "completed", passed: []}),
    do: {:fail, "nothing scored above the threshold, so nothing was delivered"}

  defp judge(:items, %{status: "completed"}),
    do: {:fail, "items passed but no message was delivered"}

  defp judge(:empty, %{status: "completed", passed: [], message: nil}), do: :pass

  defp judge(:empty, %{status: "completed", message: message}) when is_binary(message),
    do: {:fail, "a message was delivered although nothing should have passed"}

  defp judge(:empty, %{status: "completed"}), do: {:fail, "items passed the threshold"}

  defp judge(_expect, %{status: status} = details),
    do: {:fail, "run #{status}: #{Map.get(details, :error) || "no error recorded"}"}

  defp title_in?(title, message) when is_binary(title) do
    String.contains?(String.downcase(message), String.downcase(String.trim(title)))
  end

  defp title_in?(_title, _message), do: false
end
