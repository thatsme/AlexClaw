defmodule AlexClaw.Skills.Dynamic.CreateTop5Hacker do
  @moduledoc "Fetches the top 5 Hacker News stories: title, score and URL."
  @behaviour AlexClaw.Skill

  alias AlexClaw.Skills.SkillAPI

  @hn "https://hacker-news.firebaseio.com/v0"

  @impl true
  def version, do: "1.1.0"

  @impl true
  def permissions, do: [:web_read]

  @impl true
  def description,
    do: "Fetches top 5 Hacker News stories and returns formatted list with title, score, and URL"

  @impl true
  def routes, do: [:on_success, :on_error]

  @impl true
  def external, do: true

  @impl true
  def step_fields, do: []

  @impl true
  @spec config_schema() :: AlexClaw.Skill.config_schema()
  def config_schema, do: %{}

  @impl true
  def run(_args) do
    case SkillAPI.http_get(__MODULE__, "#{@hn}/topstories.json") do
      {:ok, %{status: 200, body: ids}} when is_list(ids) ->
        ids
        |> Enum.take(5)
        |> Enum.map(&{&1, fetch_story(&1)})
        |> result()

      {:ok, %{status: status}} ->
        {:error, "Failed to fetch top stories: HTTP #{status}"}

      {:error, reason} ->
        {:error, "Failed to fetch top stories: #{inspect(reason)}"}
    end
  end

  defp fetch_story(id) do
    case SkillAPI.http_get(__MODULE__, "#{@hn}/item/#{id}.json") do
      {:ok, %{status: 200, body: story}} when is_map(story) ->
        {:ok, {story["title"] || "No Title", story["score"] || 0, story["url"] || "No URL"}}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  # Every story failing is a failure, not a list of "Error fetching story"
  # lines; some failing are named after the stories that arrived.
  defp result(stories) do
    fetched = for {_id, {:ok, story}} <- stories, do: story
    failed = for {id, {:error, why}} <- stories, do: "story #{id} (#{why})"
    outcome(fetched, failed)
  end

  defp outcome([], []), do: {:error, "Hacker News returned no top stories"}
  defp outcome([], failed), do: {:error, "Every top story failed: " <> Enum.join(failed, ", ")}
  defp outcome(fetched, failed), do: {:ok, format(fetched) <> not_fetched(failed), :on_success}

  defp format(stories) do
    Enum.map_join(stories, "\n\n", fn {title, score, url} ->
      "- **#{title}** (Score: #{score})\n  #{url}"
    end)
  end

  defp not_fetched([]), do: ""
  defp not_fetched(failed), do: "\n\nNot fetched: " <> Enum.join(failed, ", ")
end
