defmodule AlexClawWeb.AdminLive.Workflows do
  @moduledoc "LiveView page for creating, editing, and managing workflows and their steps."
  use Phoenix.LiveView

  alias AlexClaw.Workflows
  alias AlexClaw.Resources
  alias AlexClaw.Workflows.SkillRegistry

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(AlexClaw.PubSub, "skills:registry")
    end

    {:ok,
     assign(socket,
       page_title: "Workflows",
       workflows: Workflows.list_workflows(),
       show_form: false,
       editing: nil,
       editing_step: nil,
       all_resources: Resources.list_resources(),
       available_skills: SkillRegistry.list_skills(),
       dynamic_skills: dynamic_skill_names(),
       llm_tiers: ~w(light medium heavy local),
       provider_choices: AlexClaw.LLM.list_provider_choices(),
       custom_schedule: false,
       adding_step: nil,
       adding_step_config: nil
     )}
  end

  @impl true
  def handle_event("toggle_form", _, socket) do
    {:noreply, assign(socket, show_form: !socket.assigns.show_form, editing: nil, editing_step: nil, custom_schedule: false)}
  end

  @impl true
  def handle_event("edit", %{"id" => id}, socket) do
    case parse_id(id) do
      {:ok, wf_id} ->
        case Workflows.get_workflow(wf_id) do
          {:ok, workflow} ->
            custom = not schedule_is_preset?(workflow.schedule)
            {:noreply, assign(socket, editing: workflow, show_form: true, editing_step: nil, custom_schedule: custom)}

          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "Workflow not found")}
        end

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("schedule_changed", %{"schedule_preset" => "custom"}, socket) do
    {:noreply, assign(socket, custom_schedule: true)}
  end

  def handle_event("schedule_changed", %{"schedule_preset" => _}, socket) do
    {:noreply, assign(socket, custom_schedule: false)}
  end

  @impl true
  def handle_event("save_workflow", params, socket) do
    schedule =
      case params["schedule_preset"] do
        "custom" -> params["schedule_custom"]
        other -> other
      end

    existing_metadata =
      case socket.assigns.editing do
        nil -> %{}
        workflow -> workflow.metadata || %{}
      end

    metadata = Map.put(existing_metadata, "requires_2fa", params["requires_2fa"] == "true")

    attrs = %{
      name: params["name"],
      description: params["description"],
      schedule: blank_to_nil(schedule),
      enabled: params["enabled"] == "true",
      default_provider: blank_to_nil(params["default_provider"]),
      metadata: metadata
    }

    result =
      case socket.assigns.editing do
        nil -> Workflows.create_workflow(attrs)
        workflow -> Workflows.update_workflow(workflow, attrs)
      end

    case result do
      {:ok, _workflow} ->
        Workflows.SchedulerSync.sync()

        {:noreply,
         socket
         |> put_flash(:info, "Workflow saved")
         |> assign(
           workflows: Workflows.list_workflows(),
           show_form: false,
           editing: nil
         )}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "Error: #{inspect(changeset.errors)}")}
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    case parse_id(id) do
      {:ok, wf_id} ->
        case Workflows.get_workflow(wf_id) do
          {:ok, workflow} ->
            {:ok, _} = Workflows.delete_workflow(workflow)
            Workflows.SchedulerSync.sync()

            {:noreply,
             socket
             |> put_flash(:info, "Workflow deleted")
             |> assign(workflows: Workflows.list_workflows())}

          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "Workflow not found")}
        end

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("run_now", %{"id" => id}, socket) do
    case parse_id(id) do
      {:ok, wf_id} ->
        Task.Supervisor.start_child(AlexClaw.TaskSupervisor, fn -> AlexClaw.Workflows.Executor.run(wf_id) end)
        {:noreply, put_flash(socket, :info, "Workflow execution started")}

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("duplicate", %{"id" => id}, socket) do
    case parse_id(id) do
      {:ok, wf_id} ->
        case Workflows.get_workflow(wf_id) do
          {:ok, workflow} ->
            case Workflows.duplicate_workflow(workflow) do
              {:ok, _new_wf} ->
                {:noreply,
                 socket
                 |> put_flash(:info, "Workflow duplicated")
                 |> assign(workflows: Workflows.list_workflows())}

              {:error, reason} ->
                {:noreply, put_flash(socket, :error, "Duplicate failed: #{inspect(reason)}")}
            end

          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "Workflow not found")}
        end

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("edit_step", %{"id" => id}, socket) do
    case parse_id(id) do
      {:ok, step_id} ->
        current = socket.assigns.editing_step

        if current && current.id == step_id do
          {:noreply, assign(socket, editing_step: nil)}
        else
          case AlexClaw.Repo.get(AlexClaw.Workflows.WorkflowStep, step_id) do
            nil -> {:noreply, put_flash(socket, :error, "Step not found")}
            step -> {:noreply, assign(socket, editing_step: step)}
          end
        end

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("save_step", params, socket) do
    step = socket.assigns.editing_step

    case parse_config_json(params["step_config"]) do
      {:ok, config} ->
        attrs = %{
          name: params["step_name"],
          skill: params["step_skill"],
          llm_tier: blank_to_nil(params["step_llm_tier"]),
          llm_model: blank_to_nil(params["step_llm_model"]),
          prompt_template: blank_to_nil(params["step_prompt_template"]),
          config: config,
          input_from: parse_input_from(params["step_input_from"])
        }

        case Workflows.update_step(step, attrs) do
          {:ok, _step} ->
            workflow = Workflows.get_workflow!(socket.assigns.editing.id)
            {:noreply, assign(socket, editing: workflow, editing_step: nil)}

          {:error, changeset} ->
            {:noreply, put_flash(socket, :error, "Step error: #{inspect(changeset.errors)}")}
        end

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Invalid config JSON: #{reason}")}
    end
  end

  @impl true
  def handle_event("cancel_edit_step", _, socket) do
    {:noreply, assign(socket, editing_step: nil)}
  end

  @impl true
  def handle_event("scaffold_config", _, socket) do
    step = socket.assigns.editing_step
    if step do
      scaffold = skill_config_scaffold(step.skill)
      # Merge scaffold with existing config to preserve user values
      existing = step.config || %{}
      merged = Map.merge(Jason.decode!(scaffold), existing)
      updated_step = Map.put(step, :config, merged)
      {:noreply, assign(socket, editing_step: updated_step)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("scaffold_config_named", %{"scaffold" => key}, socket) do
    step = socket.assigns.editing_step
    if step do
      scaffolds = skill_scaffolds(step.skill)
      config = Jason.decode!(scaffolds[key] || "{}")
      updated_step = Map.put(step, :config, config)
      {:noreply, assign(socket, editing_step: updated_step)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("begin_add_step", %{"skill" => ""}, socket) do
    {:noreply, socket}
  end

  def handle_event("begin_add_step", %{"skill" => skill}, socket) do
    {:noreply, assign(socket, adding_step: skill, adding_step_config: skill_config_scaffold(skill))}
  end

  @impl true
  def handle_event("cancel_add_step", _, socket) do
    {:noreply, assign(socket, adding_step: nil, adding_step_config: nil)}
  end

  @impl true
  def handle_event("set_add_scaffold", %{"scaffold" => key}, socket) do
    skill = socket.assigns.adding_step
    scaffolds = skill_scaffolds(skill)
    config = scaffolds[key] || ""
    {:noreply, assign(socket, adding_step_config: config)}
  end

  @impl true
  def handle_event("add_step", params, socket) do
    workflow = socket.assigns.editing

    case parse_config_json(params["step_config"]) do
      {:ok, config} ->
        attrs = %{
          name: params["step_name"],
          skill: params["step_skill"],
          llm_tier: blank_to_nil(params["step_llm_tier"]),
          llm_model: blank_to_nil(params["step_llm_model"]),
          prompt_template: blank_to_nil(params["step_prompt_template"]),
          config: config,
          input_from: parse_input_from(params["step_input_from"])
        }

        case Workflows.add_step(workflow, attrs) do
          {:ok, _step} ->
            workflow = Workflows.get_workflow!(workflow.id)
            {:noreply, assign(socket, editing: workflow, adding_step: nil)}

          {:error, changeset} ->
            {:noreply, put_flash(socket, :error, "Step error: #{inspect(changeset.errors)}")}
        end

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Invalid config JSON: #{reason}")}
    end
  end

  @impl true
  def handle_event("remove_step", %{"id" => id}, socket) do
    case parse_id(id) do
      {:ok, step_id} ->
        case AlexClaw.Repo.get(AlexClaw.Workflows.WorkflowStep, step_id) do
          nil ->
            {:noreply, put_flash(socket, :error, "Step not found")}

          step ->
            {:ok, _} = Workflows.remove_step(step)
            workflow = Workflows.get_workflow!(socket.assigns.editing.id)
            {:noreply, assign(socket, editing: workflow, editing_step: nil)}
        end

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("move_step_up", %{"id" => id}, socket) do
    case parse_id(id) do
      {:ok, step_id} -> reorder_step(socket, step_id, :up)
      :error -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("move_step_down", %{"id" => id}, socket) do
    case parse_id(id) do
      {:ok, step_id} -> reorder_step(socket, step_id, :down)
      :error -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("assign_resource", %{"resource_id" => resource_id}, socket) do
    case parse_id(resource_id) do
      {:ok, rid} ->
        workflow = socket.assigns.editing
        Workflows.assign_resource(workflow, rid)
        workflow = Workflows.get_workflow!(workflow.id)
        {:noreply, assign(socket, editing: workflow)}

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("unassign_resource", %{"resource_id" => resource_id}, socket) do
    case parse_id(resource_id) do
      {:ok, rid} ->
        workflow = socket.assigns.editing
        Workflows.unassign_resource(workflow, rid)
        workflow = Workflows.get_workflow!(workflow.id)
        {:noreply, assign(socket, editing: workflow)}

      :error ->
        {:noreply, socket}
    end
  end

  defp reorder_step(socket, step_id, direction) do
    workflow = socket.assigns.editing
    steps = workflow.steps
    idx = Enum.find_index(steps, &(&1.id == step_id))

    new_order =
      case direction do
        :up when idx > 0 ->
          steps |> List.delete_at(idx) |> List.insert_at(idx - 1, Enum.at(steps, idx))
        :down when idx < length(steps) - 1 ->
          steps |> List.delete_at(idx) |> List.insert_at(idx + 1, Enum.at(steps, idx))
        _ ->
          steps
      end

    step_ids = Enum.map(new_order, & &1.id)
    Workflows.reorder_steps(workflow, step_ids)
    workflow = Workflows.get_workflow!(workflow.id)
    {:noreply, assign(socket, editing: workflow)}
  end

  @impl true
  def handle_info({:skill_registered, _name}, socket) do
    {:noreply,
     assign(socket,
       available_skills: SkillRegistry.list_skills(),
       dynamic_skills: dynamic_skill_names()
     )}
  end

  def handle_info({:skill_unregistered, _name}, socket) do
    {:noreply,
     assign(socket,
       available_skills: SkillRegistry.list_skills(),
       dynamic_skills: dynamic_skill_names()
     )}
  end

  defp dynamic_skill_names do
    SkillRegistry.list_all_with_type()
    |> Enum.filter(fn {_, _, type, _} -> type == :dynamic end)
    |> Enum.map(&elem(&1, 0))
    |> MapSet.new()
  end

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {i, ""} -> {:ok, i}
      _ -> :error
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(val), do: val

  defp parse_input_from(nil), do: nil
  defp parse_input_from(""), do: nil
  defp parse_input_from(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_config_json(nil), do: {:ok, %{}}
  defp parse_config_json(""), do: {:ok, %{}}
  defp parse_config_json(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _} -> {:error, "must be a JSON object"}
      {:error, %Jason.DecodeError{} = err} -> {:error, Exception.message(err)}
    end
  end

  defp format_config(nil), do: ""
  defp format_config(config) when config == %{}, do: ""
  defp format_config(config), do: Jason.encode!(config, pretty: true)

  @schedule_presets [
    {"", "Manual (no schedule)"},
    {"*/15 * * * *", "Every 15 minutes"},
    {"*/30 * * * *", "Every 30 minutes"},
    {"0 * * * *", "Every hour"},
    {"0 */2 * * *", "Every 2 hours"},
    {"0 */4 * * *", "Every 4 hours"},
    {"0 */6 * * *", "Every 6 hours"},
    {"0 */12 * * *", "Every 12 hours"},
    {"0 7 * * *", "Daily at 7:00"},
    {"0 8 * * *", "Daily at 8:00"},
    {"0 9 * * *", "Daily at 9:00"},
    {"0 12 * * *", "Daily at 12:00"},
    {"0 18 * * *", "Daily at 18:00"},
    {"0 21 * * *", "Daily at 21:00"},
    {"0 7 * * 1-5", "Weekdays at 7:00"},
    {"0 9 * * 1-5", "Weekdays at 9:00"},
    {"0 9 * * 1", "Weekly on Monday 9:00"},
    {"0 9 * * 5", "Weekly on Friday 9:00"},
    {"0 9 1 * *", "Monthly on 1st at 9:00"},
    {"custom", "Custom cron..."}
  ]

  defp schedule_presets, do: @schedule_presets

  defp schedule_is_preset?(nil), do: true
  defp schedule_is_preset?(""), do: true
  defp schedule_is_preset?(schedule) do
    Enum.any?(@schedule_presets, fn {cron, _} -> cron == schedule end)
  end

  defp schedule_label(nil), do: "Manual"
  defp schedule_label(""), do: "Manual"
  defp schedule_label(schedule) do
    case Enum.find(@schedule_presets, fn {cron, _} -> cron == schedule end) do
      {_, label} -> label
      nil -> schedule
    end
  end

  defp skill_uses_llm?("telegram_notify"), do: false
  defp skill_uses_llm?("api_request"), do: false
  defp skill_uses_llm?("rss_collector"), do: false
  defp skill_uses_llm?("web_browse"), do: false
  defp skill_uses_llm?("google_calendar"), do: false
  defp skill_uses_llm?("google_tasks"), do: false
  defp skill_uses_llm?("web_automation"), do: false
  defp skill_uses_llm?(_), do: true

  defp skill_config_hint("api_request"), do: ~s|{"method": "GET", "url": "https://...", "headers": {}, "body": ""}|
  defp skill_config_hint("rss_collector"), do: ~s|{"threshold": 0.3, "force": false, "max_items": 5, "interests": "topics to score for"}|
  defp skill_config_hint("web_search"), do: ~s|{"query": "search terms"}|
  defp skill_config_hint("web_browse"), do: ~s|{"url": "https://...", "question": "optional"}|
  defp skill_config_hint("llm_transform"), do: ~s|{"context": "extra context for {context} placeholder"}|
  defp skill_config_hint("telegram_notify"), do: ~s|{"chat_id": "optional", "bot_token": "optional", "parse_mode": "Markdown"}|
  defp skill_config_hint("google_calendar"), do: ~s|{"action": "list", "days": 1} or {"action": "create", "title": "Meeting", "date": "2026-03-20", "time": "14:00"}|
  defp skill_config_hint("google_tasks"), do: ~s|{"action": "list"} or {"action": "create", "title": "Task title"}|
  defp skill_config_hint("github_security_review"), do: ~s|{"repo": "owner/repo", "pr": 42}|
  defp skill_config_hint("web_automation"), do: ~s|{"action": "play"} — runs the automation config from the assigned Resource|
  defp skill_config_hint("research"), do: ~s|{"query": "research topic"}|
  defp skill_config_hint("conversational"), do: ~s|{"message": "text to send"}|
  defp skill_config_hint(_), do: ""

  defp skill_config_scaffold(skill) do
    case skill do
      "api_request" -> %{"method" => "GET", "url" => "", "headers" => %{}, "body" => ""}
      "rss_collector" -> %{"threshold" => 0.3, "force" => false, "max_items" => 5, "interests" => ""}
      "web_search" -> %{"query" => ""}
      "web_browse" -> %{"url" => "", "question" => ""}
      "llm_transform" -> %{"context" => ""}
      "telegram_notify" -> %{"chat_id" => "", "bot_token" => "", "parse_mode" => "Markdown"}
      "google_calendar" -> %{"action" => "list", "calendar_id" => "primary", "days" => 1, "max_results" => 20}
      "google_tasks" -> %{"action" => "list", "task_list" => "@default"}
      "github_security_review" -> %{"repo" => "", "pr" => nil}
      "web_automation" -> %{"action" => "play", "resource" => "automation resource name"}
      "research" -> %{"query" => ""}
      "conversational" -> %{"message" => ""}
      _ -> %{}
    end
    |> Jason.encode!(pretty: true)
  end

  defp skill_scaffolds(skill) do
    case skill do
      "google_tasks" -> %{
        "List tasks" => Jason.encode!(%{"action" => "list", "task_list" => "My Tasks", "max_results" => 20, "show_completed" => false}, pretty: true),
        "Add task" => Jason.encode!(%{"action" => "add", "task_list" => "My Tasks", "title" => "Task title (step input becomes notes)", "due" => "2026-03-20"}, pretty: true),
        "Add task (input as title)" => Jason.encode!(%{"action" => "add", "task_list" => "My Tasks"}, pretty: true),
        "List task lists" => Jason.encode!(%{"action" => "lists"}, pretty: true)
      }
      "google_calendar" -> %{
        "List events" => Jason.encode!(%{"action" => "list", "calendar_id" => "primary", "days" => 1, "max_results" => 20}, pretty: true),
        "Create event" => Jason.encode!(%{"action" => "create", "title" => "Meeting", "date" => "2026-03-20", "time" => "14:00", "duration" => 60}, pretty: true)
      }
      "api_request" -> %{
        "GET" => Jason.encode!(%{"method" => "GET", "url" => "https://...", "headers" => %{}}, pretty: true),
        "POST" => Jason.encode!(%{"method" => "POST", "url" => "https://...", "headers" => %{"content-type" => "application/json"}, "body" => "{}"}, pretty: true)
      }
      "web_automation" -> %{
        "Play" => Jason.encode!(%{"action" => "play"}, pretty: true),
        "Record" => Jason.encode!(%{"action" => "record", "url" => "https://..."}, pretty: true)
      }
      _ -> %{}
    end
  end

  defp skill_has_scaffolds?(skill), do: skill_scaffolds(skill) != %{}

  defp skill_help(skill) do
    prompt = case skill do
      "llm_transform" -> "Template sent to the LLM. Use {input} for previous step output, {context} for config context."
      "research" -> "Research query template. Use {input} to include data from the previous step."
      "conversational" -> "Message template. Use {input} to include data from the previous step."
      _ -> "Template sent to the LLM. Use {input} for previous step output."
    end

    config = case skill do
      "api_request" -> "HTTP request parameters: method, url, headers, body. The response becomes the next step's input."
      "rss_collector" -> "threshold: minimum relevance score (0-1). force: re-fetch even if cached. max_items: limit results. interests: topics for scoring."
      "web_search" -> "query: the search terms. Leave empty to use {input} from the previous step."
      "web_browse" -> "url: page to fetch. question: optional question to answer about the page content."
      "llm_transform" -> "context: extra text available as {context} in the prompt template. Usually empty — most config goes in the prompt."
      "telegram_notify" -> "Optional overrides. Leave empty to use default bot/chat. parse_mode: Markdown or HTML."
      "google_calendar" -> "action: list (fetch events) or create (new event with title, date, time). calendar_id: which calendar (default: primary). days: how many days ahead. max_results: event limit."
      "google_tasks" -> "action: list or add. For add: set title in config and the step input becomes notes automatically. Or leave title empty and input becomes the title. due: optional date (YYYY-MM-DD). task_list: list ID (default: @default)."
      "github_security_review" -> "repo: owner/repo format. pr: PR number. Or commit_sha for commit review."
      "web_automation" -> "action: play (run automation), record (start recording), status (check sidecar). The automation config comes from the assigned Resource (type: automation)."
      "research" -> "query: the research topic. Leave empty to use {input} from the previous step."
      "conversational" -> "message: text to send to the LLM. Leave empty to use {input} from the previous step."
      _ -> "Skill-specific parameters as JSON. Click Scaffold to see available options."
    end

    %{prompt: prompt, config: config}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-8">
      <div class="flex justify-between items-center">
        <h1 class="text-2xl font-bold text-white">Workflows</h1>
        <button phx-click="toggle_form" class="px-4 py-2 bg-claw-700 hover:bg-claw-600 text-white text-sm rounded transition">
          {if @show_form && !@editing, do: "Cancel", else: "New Workflow"}
        </button>
      </div>

      <div :if={@show_form && !@editing} class="bg-gray-900 rounded-lg border border-gray-800 p-6">
        <h2 class="text-lg font-semibold text-white mb-4">New Workflow</h2>
        <form phx-submit="save_workflow" class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <div>
            <label class="block text-sm text-gray-400 mb-1">Name</label>
            <input type="text" name="name" required
              class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-2 text-white text-sm" />
          </div>
          <div>
            <label class="block text-sm text-gray-400 mb-1">Schedule</label>
            <select name="schedule_preset" phx-change="schedule_changed"
              class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-2 text-white text-sm">
              <option :for={{cron, label} <- schedule_presets()} value={cron}>{label}</option>
            </select>
            <input :if={@custom_schedule} type="text" name="schedule_custom" placeholder="*/5 * * * *"
              class="w-full mt-2 bg-gray-800 border border-gray-700 rounded px-3 py-2 text-white text-sm font-mono" />
          </div>
          <div class="md:col-span-2">
            <label class="block text-sm text-gray-400 mb-1">Description</label>
            <input type="text" name="description"
              class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-2 text-white text-sm" />
          </div>
          <input type="hidden" name="enabled" value="true" />
          <div class="flex items-center gap-4">
            <label class="flex items-center gap-2 text-sm text-gray-400">
              <input type="checkbox" name="requires_2fa" value="true" class="rounded bg-gray-800 border-gray-700" />
              Requires 2FA
            </label>
          </div>
          <div class="md:col-span-2">
            <button type="submit" class="px-4 py-2 bg-green-700 hover:bg-green-600 text-white text-sm rounded transition">Create</button>
          </div>
        </form>
      </div>

      <div :if={@editing} class="bg-gray-900 rounded-lg border border-gray-800 p-6 space-y-6">
        <div class="flex justify-between items-center">
          <h2 class="text-lg font-semibold text-white">Editing: {@editing.name}</h2>
          <button phx-click="toggle_form" class="text-sm text-gray-400 hover:text-white">Close</button>
        </div>

        <form phx-submit="save_workflow" class="grid grid-cols-1 md:grid-cols-3 gap-4">
          <div>
            <label class="block text-sm text-gray-400 mb-1">Name</label>
            <input type="text" name="name" required value={@editing.name}
              class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-2 text-white text-sm" />
          </div>
          <div>
            <label class="block text-sm text-gray-400 mb-1">Schedule</label>
            <select name="schedule_preset" phx-change="schedule_changed"
              class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-2 text-white text-sm">
              <option :for={{cron, label} <- schedule_presets()} value={cron}
                selected={if(@custom_schedule, do: cron == "custom", else: (@editing.schedule || "") == cron)}>
                {label}
              </option>
            </select>
            <input :if={@custom_schedule} type="text" name="schedule_custom" value={@editing.schedule || ""}
              class="w-full mt-2 bg-gray-800 border border-gray-700 rounded px-3 py-2 text-white text-sm font-mono"
              placeholder="*/5 * * * *" />
          </div>
          <div>
            <label class="block text-sm text-gray-400 mb-1">Enabled</label>
            <select name="enabled" class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-2 text-white text-sm">
              <option value="true" selected={@editing.enabled}>Yes</option>
              <option value="false" selected={!@editing.enabled}>No</option>
            </select>
          </div>
          <div>
            <label class="block text-sm text-gray-400 mb-1">Description</label>
            <input type="text" name="description" value={@editing.description || ""}
              class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-2 text-white text-sm" />
          </div>
          <div>
            <label class="block text-sm text-gray-400 mb-1">Default Provider</label>
            <select name="default_provider" class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-2 text-white text-sm">
              <option :for={pc <- @provider_choices} value={pc.value} selected={(@editing.default_provider || "auto") == pc.value}>
                {pc.label}
              </option>
            </select>
          </div>
          <div class="flex items-center gap-4">
            <label class="flex items-center gap-2 text-sm text-gray-400">
              <input type="checkbox" name="requires_2fa" value="true"
                checked={@editing.metadata["requires_2fa"] == true}
                class="rounded bg-gray-800 border-gray-700" />
              Requires 2FA
            </label>
          </div>
          <div class="flex items-end">
            <button type="submit" class="px-4 py-2 bg-green-700 hover:bg-green-600 text-white text-sm rounded transition">Save</button>
          </div>
        </form>

        <div>
          <h3 class="text-md font-semibold text-white mb-3">Steps</h3>
          <div class="space-y-2">
            <div :for={step <- @editing.steps} class="bg-gray-800 rounded overflow-hidden">
              <div class="p-3 flex items-center justify-between">
                <div class="flex items-center space-x-3 cursor-pointer" phx-click="edit_step" phx-value-id={step.id}>
                  <span class="text-xs text-gray-500 font-mono w-6">{step.position}</span>
                  <span class="text-sm text-white font-semibold">{step.name}</span>
                  <span class="text-xs px-2 py-0.5 rounded bg-gray-700 text-claw-500">{step.skill}</span>
                  <span :if={step.llm_tier} class="text-xs px-2 py-0.5 rounded bg-gray-700 text-yellow-400">{step.llm_tier}</span>
                  <span :if={step.llm_model && step.llm_model != "" && step.llm_model != "auto"} class="text-xs px-2 py-0.5 rounded bg-gray-700 text-green-400">{step.llm_model}</span>
                  <span :if={step.prompt_template} class="text-xs text-gray-600">has prompt</span>
                  <span :if={step.input_from} class="text-xs px-2 py-0.5 rounded bg-gray-700 text-orange-400">input from step {step.input_from}</span>
                </div>
                <div class="flex items-center space-x-2">
                  <button phx-click="edit_step" phx-value-id={step.id}
                    class="text-xs text-claw-500 hover:text-claw-400">{if @editing_step && @editing_step.id == step.id, do: "Close", else: "Edit"}</button>
                  <button phx-click="move_step_up" phx-value-id={step.id} class="text-xs text-gray-400 hover:text-white">Up</button>
                  <button phx-click="move_step_down" phx-value-id={step.id} class="text-xs text-gray-400 hover:text-white">Down</button>
                  <button phx-click="remove_step" phx-value-id={step.id}
                    data-confirm="Remove this step?"
                    class="text-xs text-red-500 hover:text-red-400">Remove</button>
                </div>
              </div>

              <div :if={@editing_step && @editing_step.id == step.id} class="border-t border-gray-700 p-4 bg-gray-850">
                <form phx-submit="save_step" class="space-y-3">
                  <div class={["grid grid-cols-1 gap-3", if(skill_uses_llm?(@editing_step.skill), do: "md:grid-cols-4", else: "md:grid-cols-2")]}>
                    <div>
                      <label class="block text-xs text-gray-500 mb-1">Step Name</label>
                      <input type="text" name="step_name" required value={@editing_step.name}
                        class="w-full bg-gray-900 border border-gray-700 rounded px-2 py-1.5 text-white text-sm" />
                    </div>
                    <div>
                      <label class="block text-xs text-gray-500 mb-1">Skill</label>
                      <select name="step_skill" class="w-full bg-gray-900 border border-gray-700 rounded px-2 py-1.5 text-white text-sm">
                        <option :for={s <- @available_skills} value={s} selected={@editing_step.skill == s}>{s}{if s in @dynamic_skills, do: " (dynamic)", else: ""}</option>
                      </select>
                    </div>
                    <div :if={skill_uses_llm?(@editing_step.skill)}>
                      <label class="block text-xs text-gray-500 mb-1">LLM Tier</label>
                      <select name="step_llm_tier" class="w-full bg-gray-900 border border-gray-700 rounded px-2 py-1.5 text-white text-sm">
                        <option value="" selected={!@editing_step.llm_tier}>None</option>
                        <option :for={t <- @llm_tiers} value={t} selected={@editing_step.llm_tier == t}>{t}</option>
                      </select>
                    </div>
                    <div :if={skill_uses_llm?(@editing_step.skill)}>
                      <label class="block text-xs text-gray-500 mb-1">Provider</label>
                      <select name="step_llm_model" class="w-full bg-gray-900 border border-gray-700 rounded px-2 py-1.5 text-white text-sm">
                        <option :for={pc <- @provider_choices} value={pc.value} selected={(@editing_step.llm_model || "auto") == pc.value}>
                          {pc.label}
                        </option>
                      </select>
                    </div>
                  </div>
                  <div :if={@editing_step.position > 1}>
                    <label class="block text-xs text-gray-500 mb-1">
                      Input from
                      <span class="relative inline-block ml-1 group">
                        <span class="inline-flex items-center justify-center w-4 h-4 rounded-full bg-gray-700 text-gray-400 text-[10px] cursor-help group-hover:bg-yellow-400 group-hover:text-black transition">?</span>
                        <span class="absolute bottom-full left-0 mb-2 px-3 py-2 bg-yellow-400 text-black text-xs rounded shadow-lg w-64 hidden group-hover:block z-50">
                          Which step's output to use as input. Default: previous step. Override to create branching workflows.
                        </span>
                      </span>
                    </label>
                    <select name="step_input_from" class="w-full bg-gray-900 border border-gray-700 rounded px-2 py-1.5 text-white text-sm">
                      <option value="" selected={!@editing_step.input_from}>Previous step (default)</option>
                      <option :for={s <- Enum.filter(@editing.steps, &(&1.position < @editing_step.position))}
                        value={s.position} selected={@editing_step.input_from == s.position}>
                        Step {s.position}: {s.name}
                      </option>
                    </select>
                  </div>
                  <div :if={skill_uses_llm?(@editing_step.skill)}>
                    <label class="block text-xs text-gray-500 mb-1">
                      Prompt Template
                      <span class="relative inline-block ml-1 group">
                        <span class="inline-flex items-center justify-center w-4 h-4 rounded-full bg-gray-700 text-gray-400 text-[10px] cursor-help group-hover:bg-yellow-400 group-hover:text-black transition">?</span>
                        <span class="absolute bottom-full left-0 mb-2 px-3 py-2 bg-yellow-400 text-black text-xs rounded shadow-lg w-64 hidden group-hover:block z-50">
                          {skill_help(@editing_step.skill).prompt}
                        </span>
                      </span>
                    </label>
                    <textarea name="step_prompt_template" rows="5"
                      placeholder="Use {input} for previous step output, {resources} for assigned resources, {context} for step config context"
                      class="w-full bg-gray-900 border border-gray-700 rounded px-2 py-1.5 text-white text-sm font-mono">{@editing_step.prompt_template || ""}</textarea>
                  </div>
                  <div>
                    <div class="flex items-center justify-between mb-1">
                      <label class="text-xs text-gray-500">
                        Config (JSON)
                        <span class="relative inline-block ml-1 group">
                          <span class="inline-flex items-center justify-center w-4 h-4 rounded-full bg-gray-700 text-gray-400 text-[10px] cursor-help group-hover:bg-yellow-400 group-hover:text-black transition">?</span>
                          <span class="absolute bottom-full left-0 mb-2 px-3 py-2 bg-yellow-400 text-black text-xs rounded shadow-lg w-72 hidden group-hover:block z-50">
                            {skill_help(@editing_step.skill).config}
                          </span>
                        </span>
                      </label>
                      <div class="flex gap-1">
                        <button :if={!skill_has_scaffolds?(@editing_step.skill)} type="button" phx-click="scaffold_config"
                          class="text-xs px-2 py-0.5 bg-gray-700 hover:bg-gray-600 text-claw-400 rounded transition">
                          Scaffold
                        </button>
                        <button :for={{label, _json} <- skill_scaffolds(@editing_step.skill)}
                          type="button" phx-click="scaffold_config_named" phx-value-scaffold={label}
                          class="text-xs px-2 py-0.5 bg-gray-700 hover:bg-gray-600 text-claw-400 rounded transition">
                          {label}
                        </button>
                      </div>
                    </div>
                    <textarea name="step_config" rows="4"
                      placeholder={skill_config_hint(@editing_step.skill)}
                      class="w-full bg-gray-900 border border-gray-700 rounded px-2 py-1.5 text-white text-sm font-mono">{format_config(@editing_step.config)}</textarea>
                  </div>
                  <div class="flex space-x-2">
                    <button type="submit" class="px-3 py-1.5 bg-green-700 hover:bg-green-600 text-white text-sm rounded transition">Save Step</button>
                    <button type="button" phx-click="cancel_edit_step" class="px-3 py-1.5 bg-gray-700 hover:bg-gray-600 text-white text-sm rounded transition">Cancel</button>
                  </div>
                </form>
              </div>
            </div>
          </div>

          <form :if={!@adding_step} phx-change="begin_add_step" class="mt-3 flex items-end gap-2">
            <div>
              <label class="block text-xs text-gray-500 mb-1">Add Step</label>
              <select name="skill" class="bg-gray-800 border border-gray-700 rounded px-2 py-1.5 text-white text-sm">
                <option value="">Select skill...</option>
                <option :for={s <- @available_skills} value={s}>{s}{if s in @dynamic_skills, do: " (dynamic)", else: ""}</option>
              </select>
            </div>
          </form>

          <div :if={@adding_step} class="mt-3 bg-gray-800 rounded border border-gray-700 p-4">
            <div class="flex items-center justify-between mb-3">
              <h4 class="text-sm font-semibold text-white">New Step — <span class="text-claw-500">{@adding_step}</span></h4>
              <button type="button" phx-click="cancel_add_step" class="text-xs text-gray-400 hover:text-white">Cancel</button>
            </div>
            <form phx-submit="add_step" class="space-y-3">
              <input type="hidden" name="step_skill" value={@adding_step} />
              <div class={["grid grid-cols-1 gap-3", if(skill_uses_llm?(@adding_step), do: "md:grid-cols-4", else: "md:grid-cols-2")]}>
                <div>
                  <label class="block text-xs text-gray-500 mb-1">Step Name</label>
                  <input type="text" name="step_name" required
                    class="w-full bg-gray-900 border border-gray-700 rounded px-2 py-1.5 text-white text-sm" />
                </div>
                <div>
                  <label class="block text-xs text-gray-500 mb-1">Skill</label>
                  <input type="text" disabled value={@adding_step}
                    class="w-full bg-gray-900 border border-gray-700 rounded px-2 py-1.5 text-gray-400 text-sm" />
                </div>
                <div :if={skill_uses_llm?(@adding_step)}>
                  <label class="block text-xs text-gray-500 mb-1">LLM Tier</label>
                  <select name="step_llm_tier" class="w-full bg-gray-900 border border-gray-700 rounded px-2 py-1.5 text-white text-sm">
                    <option value="">None</option>
                    <option :for={t <- @llm_tiers} value={t}>{t}</option>
                  </select>
                </div>
                <div :if={skill_uses_llm?(@adding_step)}>
                  <label class="block text-xs text-gray-500 mb-1">Provider</label>
                  <select name="step_llm_model" class="w-full bg-gray-900 border border-gray-700 rounded px-2 py-1.5 text-white text-sm">
                    <option :for={pc <- @provider_choices} value={pc.value}>{pc.label}</option>
                  </select>
                </div>
              </div>
              <div :if={@editing && length(@editing.steps) > 0}>
                <label class="block text-xs text-gray-500 mb-1">
                  Input from
                  <span class="relative inline-block ml-1 group">
                    <span class="inline-flex items-center justify-center w-4 h-4 rounded-full bg-gray-700 text-gray-400 text-[10px] cursor-help group-hover:bg-yellow-400 group-hover:text-black transition">?</span>
                    <span class="absolute bottom-full left-0 mb-2 px-3 py-2 bg-yellow-400 text-black text-xs rounded shadow-lg w-64 hidden group-hover:block z-50">
                      Which step's output to use as input. Default: previous step. Override to create branching workflows.
                    </span>
                  </span>
                </label>
                <select name="step_input_from" class="w-full bg-gray-900 border border-gray-700 rounded px-2 py-1.5 text-white text-sm">
                  <option value="">Previous step (default)</option>
                  <option :for={s <- @editing.steps} value={s.position}>
                    Step {s.position}: {s.name}
                  </option>
                </select>
              </div>
              <div :if={skill_uses_llm?(@adding_step)}>
                <label class="block text-xs text-gray-500 mb-1">
                  Prompt Template
                  <span class="relative inline-block ml-1 group">
                    <span class="inline-flex items-center justify-center w-4 h-4 rounded-full bg-gray-700 text-gray-400 text-[10px] cursor-help group-hover:bg-yellow-400 group-hover:text-black transition">?</span>
                    <span class="absolute bottom-full left-0 mb-2 px-3 py-2 bg-yellow-400 text-black text-xs rounded shadow-lg w-64 hidden group-hover:block z-50">
                      {skill_help(@adding_step).prompt}
                    </span>
                  </span>
                </label>
                <textarea name="step_prompt_template" rows="4"
                  placeholder="Use {input} for previous step output"
                  class="w-full bg-gray-900 border border-gray-700 rounded px-2 py-1.5 text-white text-sm font-mono"></textarea>
              </div>
              <div>
                <div class="flex items-center justify-between mb-1">
                  <label class="text-xs text-gray-500">
                    Config (JSON)
                    <span class="relative inline-block ml-1 group">
                      <span class="inline-flex items-center justify-center w-4 h-4 rounded-full bg-gray-700 text-gray-400 text-[10px] cursor-help group-hover:bg-yellow-400 group-hover:text-black transition">?</span>
                      <span class="absolute bottom-full left-0 mb-2 px-3 py-2 bg-yellow-400 text-black text-xs rounded shadow-lg w-72 hidden group-hover:block z-50">
                        {skill_help(@adding_step).config}
                      </span>
                    </span>
                  </label>
                  <div :if={skill_has_scaffolds?(@adding_step)} class="flex gap-1">
                    <button :for={{label, _json} <- skill_scaffolds(@adding_step)}
                      type="button" phx-click="set_add_scaffold" phx-value-scaffold={label}
                      class="text-xs px-2 py-0.5 bg-gray-700 hover:bg-gray-600 text-claw-400 rounded transition">
                      {label}
                    </button>
                  </div>
                </div>
                <textarea name="step_config" rows="3"
                  placeholder={skill_config_hint(@adding_step)}
                  class="w-full bg-gray-900 border border-gray-700 rounded px-2 py-1.5 text-white text-sm font-mono">{@adding_step_config || skill_config_scaffold(@adding_step)}</textarea>
              </div>
              <div class="flex space-x-2">
                <button type="submit" class="px-3 py-1.5 bg-green-700 hover:bg-green-600 text-white text-sm rounded transition">Save Step</button>
                <button type="button" phx-click="cancel_add_step" class="px-3 py-1.5 bg-gray-700 hover:bg-gray-600 text-white text-sm rounded transition">Cancel</button>
              </div>
            </form>
          </div>
        </div>

        <div>
          <h3 class="text-md font-semibold text-white mb-3">Assigned Resources</h3>
          <div class="space-y-1 mb-3">
            <div :for={wr <- @editing.workflow_resources} class="bg-gray-800 rounded p-2 flex items-center justify-between">
              <span class="text-sm text-white">{find_resource_name(@all_resources, wr.resource_id)}</span>
              <div class="flex items-center space-x-2">
                <span class="text-xs text-gray-500">{wr.role}</span>
                <button phx-click="unassign_resource" phx-value-resource_id={wr.resource_id}
                  class="text-xs text-red-500 hover:text-red-400">Remove</button>
              </div>
            </div>
            <p :if={@editing.workflow_resources == []} class="text-sm text-gray-500">No resources assigned</p>
          </div>
          <div class="flex items-center space-x-2">
            <form phx-submit="assign_resource" class="flex items-center space-x-2">
              <select name="resource_id" class="bg-gray-800 border border-gray-700 rounded px-2 py-1.5 text-white text-sm">
                <option :for={r <- unassigned_resources(@all_resources, @editing.workflow_resources)} value={r.id}>
                  {r.name} ({r.type})
                </option>
              </select>
              <button type="submit" class="px-3 py-1.5 bg-claw-700 hover:bg-claw-600 text-white text-sm rounded transition">
                Assign
              </button>
            </form>
          </div>
        </div>
      </div>

      <div class="bg-gray-900 rounded-lg border border-gray-800 overflow-hidden">
        <table class="w-full table-fixed">
          <thead class="bg-gray-800">
            <tr>
              <th class="w-2/5 px-4 py-3 text-left text-xs text-gray-400 uppercase">Name</th>
              <th class="w-1/6 px-4 py-3 text-left text-xs text-gray-400 uppercase">Schedule</th>
              <th class="w-14 px-4 py-3 text-left text-xs text-gray-400 uppercase">Steps</th>
              <th class="w-20 px-4 py-3 text-left text-xs text-gray-400 uppercase">Status</th>
              <th class="w-14 px-4 py-3 text-left text-xs text-gray-400 uppercase">Runs</th>
              <th class="px-4 py-3 text-right text-xs text-gray-400 uppercase">Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@workflows == []} class="border-t border-gray-800">
              <td colspan="6" class="px-4 py-8 text-center text-gray-500">No workflows yet</td>
            </tr>
            <tr :for={wf <- @workflows} class="border-t border-gray-800">
              <td class="px-4 py-3">
                <div class="text-sm font-semibold text-white truncate">{wf.name}</div>
                <div :if={wf.description} class="text-xs text-gray-500 break-words">{wf.description}</div>
              </td>
              <td class="px-4 py-3 text-sm text-gray-400">
                <span>{schedule_label(wf.schedule)}</span>
                <span :if={wf.schedule && !schedule_is_preset?(wf.schedule)} class="text-xs text-gray-600 font-mono ml-1">({wf.schedule})</span>
              </td>
              <td class="px-4 py-3 text-sm text-gray-400">{length(load_steps(wf.id))}</td>
              <td class="px-4 py-3">
                <span :if={wf.enabled} class="text-xs px-2 py-1 rounded bg-green-900 text-green-300">enabled</span>
                <span :if={!wf.enabled} class="text-xs px-2 py-1 rounded bg-gray-800 text-gray-500">disabled</span>
              </td>
              <td class="px-4 py-3 text-sm text-gray-400">{count_runs(wf.id)}</td>
              <td class="px-4 py-3 text-right whitespace-nowrap space-x-2">
                <button phx-click="run_now" phx-value-id={wf.id}
                  class="text-xs text-green-500 hover:text-green-400">Run</button>
                <a href={"/workflows/#{wf.id}/runs"} class="text-xs text-claw-500 hover:text-claw-400">Runs</a>
                <button phx-click="duplicate" phx-value-id={wf.id}
                  class="text-xs text-yellow-500 hover:text-yellow-400">Clone</button>
                <button phx-click="edit" phx-value-id={wf.id}
                  class="text-xs text-claw-500 hover:text-claw-400">Edit</button>
                <button phx-click="delete" phx-value-id={wf.id}
                  data-confirm="Delete this workflow and all its steps?"
                  class="text-xs text-red-500 hover:text-red-400">Del</button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp load_steps(workflow_id) do
    import Ecto.Query
    AlexClaw.Repo.all(from s in AlexClaw.Workflows.WorkflowStep, where: s.workflow_id == ^workflow_id)
  end

  defp count_runs(workflow_id) do
    import Ecto.Query
    AlexClaw.Repo.one(from r in AlexClaw.Workflows.WorkflowRun, where: r.workflow_id == ^workflow_id, select: count(r.id))
  end

  defp find_resource_name(resources, resource_id) do
    case Enum.find(resources, &(&1.id == resource_id)) do
      nil -> "Unknown"
      r -> r.name
    end
  end

  defp unassigned_resources(all_resources, workflow_resources) do
    assigned_ids = MapSet.new(workflow_resources, & &1.resource_id)
    Enum.reject(all_resources, &MapSet.member?(assigned_ids, &1.id))
  end
end
