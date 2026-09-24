defmodule AlexClaw.Skills.GoogleTasks do
  @moduledoc """
  Google Tasks skill. Lists and creates tasks via the Google Tasks API.

  Shares OAuth credentials with Google Calendar via TokenManager.

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

  alias AlexClaw.Google.TokenManager
  @impl true
  @spec external() :: boolean()
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
  @spec step_fields() :: [atom()]
  def step_fields, do: [:config]

  @impl true
  @spec config_hint() :: String.t()
  def config_hint, do: ~s|{"action": "list"} or {"action": "create", "title": "Task title"}|

  @impl true
  @spec config_scaffold() :: map()
  def config_scaffold, do: %{"action" => "list", "task_list" => "@default"}

  @impl true
  @spec config_schema() :: AlexClaw.Skill.config_schema()
  def config_schema do
    %{
      "action" => %{type: :string, required: false},
      "task_list" => %{type: :string, required: false},
      "max_results" => %{type: :integer, required: false},
      "show_completed" => %{type: :boolean, required: false},
      "title" => %{type: :string, required: false},
      "notes" => %{type: :string, required: false},
      "due" => %{type: :string, required: false}
    }
  end

  @impl true
  @spec available?() :: boolean()
  def available?, do: TokenManager.configured?()

  @impl true
  @spec config_presets() :: %{String.t() => map()}
  def config_presets do
    %{
      "List tasks" => %{
        "action" => "list",
        "task_list" => "My Tasks",
        "max_results" => 20,
        "show_completed" => false
      },
      "Add task" => %{
        "action" => "add",
        "task_list" => "My Tasks",
        "title" => "Task title (step input becomes notes)",
        "due" => "2026-03-20"
      },
      "Add task (input as title)" => %{"action" => "add", "task_list" => "My Tasks"},
      "List task lists" => %{"action" => "lists"}
    }
  end

  @impl true
  @spec config_help() :: String.t()
  def config_help,
    do:
      "action: list or add. For add: set title in config and the step input becomes notes automatically. Or leave title empty and input becomes the title. due: optional date (YYYY-MM-DD). task_list: list ID (default: @default)."

  @impl true
  @spec run(map()) :: {:ok, String.t()} | {:error, any()}
  def run(args) do
    config = args[:config] || %{}
    dispatch_action(TokenManager.get_token(), config["action"] || "list", config, args[:input])
  end

  defp dispatch_action({:error, reason}, _action, _config, _input), do: {:error, reason}

  defp dispatch_action({:ok, token}, "list", config, _input), do: list_tasks(token, config)
  defp dispatch_action({:ok, token}, "add", config, input), do: add_task(token, config, input)
  defp dispatch_action({:ok, token}, "lists", _config, _input), do: list_task_lists(token)

  defp dispatch_action({:ok, _token}, action, _config, _input) do
    {:error, {:unknown_action, action}}
  end

  defp list_tasks(token, config) do
    token
    |> resolve_task_list(config["task_list"] || "@default")
    |> fetch_tasks(token, config)
  end

  defp fetch_tasks({:error, reason}, _token, _config), do: {:error, reason}

  defp fetch_tasks({:ok, task_list_id}, token, config) do
    params = [
      maxResults: parse_int(config["max_results"], 20),
      showCompleted: config["show_completed"] in [true, "true"]
    ]

    "#{@tasks_api}/lists/#{URI.encode(task_list_id)}/tasks"
    |> Req.get(
      params: params,
      headers: [{"authorization", "Bearer #{token}"}],
      receive_timeout: 10_000
    )
    |> tasks_response()
  end

  defp tasks_response({:ok, %{status: 200, body: %{"items" => tasks}}}) when tasks != [] do
    Logger.info("GoogleTasks: fetched #{length(tasks)} tasks", skill: :google_tasks)
    {:ok, format_tasks(tasks), :on_tasks}
  end

  defp tasks_response({:ok, %{status: 200, body: _}}), do: {:ok, "No tasks found.", :on_empty}

  defp tasks_response({:ok, %{status: status, body: body}}) do
    Logger.warning("Google Tasks API error: #{status}", skill: :google_tasks)
    {:error, {:tasks_api, status, body}}
  end

  defp tasks_response({:error, reason}), do: {:error, reason}

  defp list_task_lists(token) do
    case fetch_task_lists(token) do
      {:ok, lists} ->
        formatted =
          lists
          |> Enum.map_join("\n", fn l -> "• #{l["title"]}" end)

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
    token
    |> fetch_task_lists()
    |> match_task_list(name_or_id)
  end

  defp match_task_list({:error, reason}, _name_or_id), do: {:error, reason}

  defp match_task_list({:ok, lists}, name_or_id) do
    lists
    |> Enum.find(&(String.downcase(&1["title"]) == String.downcase(name_or_id)))
    |> matched_list_id(name_or_id)
  end

  # No title matched, so treat the value as an id already.
  defp matched_list_id(nil, name_or_id), do: {:ok, name_or_id}
  defp matched_list_id(list, _name_or_id), do: {:ok, list["id"]}

  defp add_task(token, config, input) do
    {title, notes} = task_title_and_notes(config, normalize_input(input))
    create_task(title, notes, token, config)
  end

  defp normalize_input(nil), do: nil
  defp normalize_input(input), do: to_string(input)

  # An explicit config title wins and demotes the step input to notes; otherwise
  # the input becomes the title.
  defp task_title_and_notes(%{"title" => title} = config, input_str)
       when is_binary(title) and title != "" do
    {title, config["notes"] || input_str}
  end

  defp task_title_and_notes(config, input_str) when is_binary(input_str) and input_str != "" do
    {input_str, config["notes"]}
  end

  defp task_title_and_notes(config, _input_str), do: {"", config["notes"]}

  defp create_task("", _notes, _token, _config), do: {:error, :no_task_title}

  defp create_task(title, notes, token, config) do
    case resolve_task_list(token, config["task_list"] || "@default") do
      {:ok, task_list_id} -> post_task(task_list_id, title, notes, token, config)
      {:error, reason} -> {:error, reason}
    end
  end

  defp post_task(task_list_id, title, notes, token, config) do
    url = "#{@tasks_api}/lists/#{URI.encode(task_list_id)}/tasks"
    headers = [{"authorization", "Bearer #{token}"}]

    %{"title" => strip_markdown(title)}
    |> put_notes(notes)
    |> put_due(config["due"])
    |> send_task(url, headers)
  end

  defp put_notes(task, nil), do: task
  defp put_notes(task, notes), do: Map.put(task, "notes", strip_markdown(notes))

  defp put_due(task, nil), do: task
  defp put_due(task, due), do: Map.put(task, "due", "#{due}T00:00:00.000Z")

  defp send_task(task, url, headers) do
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
    |> Enum.map_join("\n", &format_task/1)
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
