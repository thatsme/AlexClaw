defmodule AlexClaw.Skills.GoogleTasks do
  @moduledoc """
  Google Tasks skill. Lists and creates tasks via the Google Tasks API.

  Shares OAuth credentials with Google Calendar via AlexClaw.Google.TokenManager.

  Configurable via step config:
  - "action" — "list" (default), "add", or "lists"
  - "task_list" — task list ID (default: "@default" = primary list)
  - "max_results" — max tasks to return when listing (default: 20)
  - "show_completed" — include completed tasks (default: false)

  When action is "add":
  - Uses input text as the task title
  - "due" — optional due date in YYYY-MM-DD format
  - "notes" — optional task notes/description

  When action is "lists":
  - Returns all task lists with their IDs (use these IDs in "task_list")
  """
  @behaviour AlexClaw.Skill
  @impl true
  def external, do: true
  @impl true
  @spec description() :: String.t()
  def description, do: "Lists and creates Google Tasks"

  @impl true
  @spec routes() :: [atom()]
  def routes, do: [:on_tasks, :on_empty, :on_error]
  require Logger
  import AlexClaw.Skills.Helpers, only: [parse_int: 2]

  @tasks_api "https://tasks.googleapis.com/tasks/v1"

  @impl true
  @spec run(map()) :: {:ok, String.t()} | {:error, any()}
  def run(args) do
    config = args[:config] || %{}
    action = config["action"] || "list"

    case AlexClaw.Google.TokenManager.get_token() do
      {:ok, token} ->
        case action do
          "list" -> list_tasks(token, config)
          "add" -> add_task(token, config, args[:input])
          "lists" -> list_task_lists(token)
          other -> {:error, {:unknown_action, other}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp list_tasks(token, config) do
    task_list_raw = config["task_list"] || "@default"
    max_results = parse_int(config["max_results"], 20)
    show_completed = config["show_completed"] == true or config["show_completed"] == "true"

    case resolve_task_list(token, task_list_raw) do
      {:ok, task_list_id} ->
        url = "#{@tasks_api}/lists/#{URI.encode(task_list_id)}/tasks"

        params = [
          maxResults: max_results,
          showCompleted: show_completed
        ]

        headers = [{"authorization", "Bearer #{token}"}]

        case Req.get(url, params: params, headers: headers, receive_timeout: 10_000) do
          {:ok, %{status: 200, body: %{"items" => tasks}}} when tasks != [] ->
            formatted = format_tasks(tasks)
            Logger.info("GoogleTasks: fetched #{length(tasks)} tasks", skill: :google_tasks)
            {:ok, formatted, :on_tasks}

          {:ok, %{status: 200, body: _}} ->
            {:ok, "No tasks found.", :on_empty}

          {:ok, %{status: status, body: body}} ->
            Logger.warning("Google Tasks API error: #{status}", skill: :google_tasks)
            {:error, {:tasks_api, status, body}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp list_task_lists(token) do
    case fetch_task_lists(token) do
      {:ok, lists} ->
        formatted = lists
          |> Enum.map(fn l -> "• #{l["title"]}" end)
          |> Enum.join("\n")
        Logger.info("GoogleTasks: fetched #{length(lists)} task lists", skill: :google_tasks)
        {:ok, formatted, :on_tasks}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_task_lists(token) do
    url = "#{@tasks_api}/users/@me/lists"
    headers = [{"authorization", "Bearer #{token}"}]

    case Req.get(url, headers: headers, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: %{"items" => lists}}} ->
        {:ok, lists}

      {:ok, %{status: 200, body: _}} ->
        {:ok, []}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Google Tasks lists API error: #{status}", skill: :google_tasks)
        {:error, {:tasks_api, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_task_list(_token, "@default"), do: {:ok, "@default"}
  defp resolve_task_list(_token, nil), do: {:ok, "@default"}
  defp resolve_task_list(_token, ""), do: {:ok, "@default"}
  defp resolve_task_list(token, name_or_id) do
    case fetch_task_lists(token) do
      {:ok, lists} ->
        case Enum.find(lists, fn l -> String.downcase(l["title"]) == String.downcase(name_or_id) end) do
          nil -> {:ok, name_or_id}  # not a name match, assume it's an ID
          list -> {:ok, list["id"]}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp add_task(token, config, input) do
    task_list_raw = config["task_list"] || "@default"
    input_str = if input, do: to_string(input), else: nil

    # If title is in config, use input as notes (if notes not explicitly set)
    # If no title in config, use input as title
    {title, notes} = cond do
      config["title"] && config["title"] != "" ->
        {config["title"], config["notes"] || input_str}
      input_str && input_str != "" ->
        {input_str, config["notes"]}
      true ->
        {"", config["notes"]}
    end

    if title == "" do
      {:error, :no_task_title}
    else
      case resolve_task_list(token, task_list_raw) do
        {:ok, task_list_id} ->
          url = "#{@tasks_api}/lists/#{URI.encode(task_list_id)}/tasks"
          headers = [{"authorization", "Bearer #{token}"}]

          task = %{"title" => strip_markdown(title)}
          task = if notes, do: Map.put(task, "notes", strip_markdown(notes)), else: task
          task = if config["due"], do: Map.put(task, "due", "#{config["due"]}T00:00:00.000Z"), else: task

          case Req.post(url, json: task, headers: headers, receive_timeout: 10_000) do
            {:ok, %{status: 200, body: %{"title" => created_title}}} ->
              Logger.info("GoogleTasks: created '#{created_title}'", skill: :google_tasks)
              {:ok, "Task created: #{created_title}", :on_tasks}

            {:ok, %{status: status, body: body}} ->
              Logger.warning("Google Tasks create failed: #{status}", skill: :google_tasks)
              {:error, {:tasks_api, status, body}}

            {:error, reason} ->
              {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp strip_markdown(text) when is_binary(text) do
    text
    |> String.replace(~r/^\#{1,6}\s+/m, "")
    |> String.replace(~r/\*\*(.+?)\*\*/s, "\\1")
    |> String.replace(~r/\*(.+?)\*/s, "\\1")
    |> String.replace(~r/__(.+?)__/s, "\\1")
    |> String.replace(~r/_(.+?)_/s, "\\1")
    |> String.replace(~r/`(.+?)`/, "\\1")
    |> String.replace(~r/^[-*+]\s+/m, "• ")
    |> String.replace(~r/^\d+\.\s+/m, "")
    |> String.replace(~r/\[([^\]]+)\]\([^\)]+\)/, "\\1")
    |> String.replace(~r/^>\s?/m, "")
    |> String.replace(~r/^---+$/m, "")
    |> String.trim()
  end
  defp strip_markdown(text), do: text

  defp format_tasks([]), do: "No tasks found."

  defp format_tasks(tasks) do
    tasks
    |> Enum.map(&format_task/1)
    |> Enum.join("\n")
  end

  defp format_task(task) do
    title = task["title"] || "(No title)"
    status = if task["status"] == "completed", do: "[done]", else: "[todo]"
    due = format_due(task["due"])
    notes = if task["notes"], do: " — #{String.slice(task["notes"], 0, 80)}", else: ""

    "#{status} #{title}#{due}#{notes}"
  end

  defp format_due(nil), do: ""
  defp format_due(due_string) do
    case Date.from_iso8601(String.slice(due_string, 0, 10)) do
      {:ok, date} -> " (due: #{date})"
      _ -> ""
    end
  end

end
