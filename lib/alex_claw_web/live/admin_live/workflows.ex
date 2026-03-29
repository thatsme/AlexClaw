defmodule AlexClawWeb.AdminLive.Workflows do
  @moduledoc "LiveView page for creating, editing, and managing workflows and their steps."
  use Phoenix.LiveView

  alias AlexClaw.Workflows
  alias AlexClaw.Resources
  alias AlexClaw.Workflows.SkillRegistry

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(AlexClaw.PubSub, "skills:registry")
      Phoenix.PubSub.subscribe(AlexClaw.PubSub, AlexClaw.Workflows.Registry.topic())
    end

    {:ok,
     socket
     |> assign(
       page_title: "Workflows",
       workflows: Workflows.list_workflows(),
       active_runs: initial_active_runs(),
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
       adding_step_config: nil,
       adding_step_prompt: nil,
       cluster_nodes: cluster_node_names(),
       show_import_form: false,
       name_filter: ""
     )
     |> allow_upload(:workflow_file,
       accept: ~w(.json),
       max_entries: 1,
       max_file_size: 1_000_000
     )}
  end

  @impl true
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
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
      node: blank_to_nil(params["node"]),
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
  def handle_event("toggle_import_form", _, socket) do
    {:noreply, assign(socket, show_import_form: !socket.assigns.show_import_form)}
  end

  @impl true
  def handle_event("filter_name", %{"name_filter" => filter}, socket) do
    {:noreply, assign(socket, name_filter: filter)}
  end

  @impl true
  def handle_event("validate_import", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("import_workflow", _params, socket) do
    result =
      consume_uploaded_entries(socket, :workflow_file, fn %{path: tmp_path}, _entry ->
        case File.read(tmp_path) do
          {:ok, content} ->
            case Jason.decode(content) do
              {:ok, data} -> {:ok, data}
              {:error, _} -> {:ok, {:parse_error, "Invalid JSON file"}}
            end

          {:error, reason} ->
            {:ok, {:read_error, "Could not read file: #{inspect(reason)}"}}
        end
      end)

    case result do
      [data] when is_map(data) ->
        case Workflows.import_workflow(data) do
          {:ok, workflow, []} ->
            {:noreply,
             socket
             |> put_flash(:info, "Workflow '#{workflow.name}' imported successfully")
             |> assign(workflows: Workflows.list_workflows(), show_import_form: false)}

          {:ok, workflow, warnings} ->
            msg = "Workflow '#{workflow.name}' imported. Warnings: #{Enum.join(warnings, "; ")}"

            {:noreply,
             socket
             |> put_flash(:info, msg)
             |> assign(workflows: Workflows.list_workflows(), show_import_form: false)}

          {:error, message} ->
            {:noreply, put_flash(socket, :error, "Import failed: #{message}")}
        end

      [{:parse_error, msg}] ->
        {:noreply, put_flash(socket, :error, msg)}

      [{:read_error, msg}] ->
        {:noreply, put_flash(socket, :error, msg)}

      [] ->
        {:noreply, put_flash(socket, :error, "No file selected")}
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
        config = merge_resilience_config(config, params)
        routes = parse_routes_from_params(params, params["step_skill"] || step.skill)

        attrs = %{
          name: params["step_name"],
          skill: params["step_skill"],
          llm_tier: blank_to_nil(params["step_llm_tier"]),
          llm_model: blank_to_nil(params["step_llm_model"]),
          prompt_template: blank_to_nil(params["step_prompt_template"]),
          config: config,
          input_from: parse_input_from(params["step_input_from"]),
          routes: routes
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
  def handle_event("scaffold_prompt", %{"scaffold" => key}, socket) do
    step = socket.assigns.editing_step
    if step do
      scaffolds = skill_prompt_scaffolds(step.skill)
      updated_step = Map.put(step, :prompt_template, scaffolds[key] || "")
      {:noreply, assign(socket, editing_step: updated_step)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("set_add_prompt_scaffold", %{"scaffold" => key}, socket) do
    skill = socket.assigns.adding_step
    scaffolds = skill_prompt_scaffolds(skill)
    {:noreply, assign(socket, adding_step_prompt: scaffolds[key] || "")}
  end

  @impl true
  def handle_event("begin_add_step", %{"skill" => ""}, socket) do
    {:noreply, socket}
  end

  def handle_event("begin_add_step", %{"skill" => skill}, socket) do
    {:noreply, assign(socket, adding_step: skill, adding_step_config: skill_config_scaffold(skill), adding_step_prompt: nil)}
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
        config = merge_resilience_config(config, params)
        routes = parse_routes_from_params(params, params["step_skill"])

        attrs = %{
          name: params["step_name"],
          skill: params["step_skill"],
          llm_tier: blank_to_nil(params["step_llm_tier"]),
          llm_model: blank_to_nil(params["step_llm_model"]),
          prompt_template: blank_to_nil(params["step_prompt_template"]),
          config: config,
          input_from: parse_input_from(params["step_input_from"]),
          routes: routes
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
  def handle_event("cancel_run", %{"run-id" => run_id_str}, socket) do
    case parse_id(run_id_str) do
      {:ok, run_id} ->
        case Workflows.cancel_run(run_id) do
          :ok -> {:noreply, put_flash(socket, :info, "Run cancelled")}
          {:error, :not_found} -> {:noreply, put_flash(socket, :error, "Run not found")}
        end

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:workflow_run_started, payload}, socket) do
    run = %{
      run_id: payload.run_id,
      workflow_id: payload.workflow_id,
      workflow_name: payload.workflow_name,
      started_at: payload.started_at,
      current_step: "starting...",
      status: :running
    }

    active = Map.put(socket.assigns.active_runs, payload.run_id, run)
    {:noreply, assign(socket, active_runs: active)}
  end

  def handle_info({event, payload}, socket)
      when event in [:workflow_step_started, :workflow_step_completed] do
    active =
      case Map.get(socket.assigns.active_runs, payload.run_id) do
        nil -> socket.assigns.active_runs
        run -> Map.put(socket.assigns.active_runs, payload.run_id, %{run | current_step: payload.step_name})
      end

    {:noreply, assign(socket, active_runs: active)}
  end

  def handle_info({event, payload}, socket)
      when event in [:workflow_run_completed, :workflow_run_failed, :workflow_run_cancelled] do
    finished_status = case event do
      :workflow_run_completed -> :completed
      :workflow_run_failed -> :failed
      :workflow_run_cancelled -> :cancelled
    end

    active =
      case Map.get(socket.assigns.active_runs, payload.run_id) do
        nil -> socket.assigns.active_runs
        run -> Map.put(socket.assigns.active_runs, payload.run_id, Map.put(run, :status, finished_status))
      end

    Process.send_after(self(), {:clear_finished_run, payload.run_id}, 10_000)
    {:noreply, assign(socket, active_runs: active)}
  end

  def handle_info({:clear_finished_run, run_id}, socket) do
    active = Map.delete(socket.assigns.active_runs, run_id)
    {:noreply, assign(socket, active_runs: active)}
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

  defp initial_active_runs do
    Map.new(Workflows.list_active_runs(), fn run -> {run.run_id, Map.put(run, :status, :running)} end)
  end

  defp dynamic_skill_names do
    SkillRegistry.list_all_with_type()
    |> Enum.filter(fn tuple -> elem(tuple, 2) == :dynamic end)
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

  defp routes_for_skill(skill_name) do
    Enum.map(SkillRegistry.get_routes(skill_name), &to_string/1)
  end

  defp route_target(step, branch) do
    case Enum.find(step.routes || [], &(&1["branch"] == branch)) do
      %{"goto" => "end"} -> "end"
      %{"goto" => pos} -> pos
      nil -> nil
    end
  end

  defp parse_routes_from_params(params, skill_name) do
    routes_for_skill(skill_name)
    |> Enum.reduce([], fn branch, acc ->
      case params["route_#{branch}"] do
        nil -> acc
        "" -> acc
        "end" -> [%{"branch" => branch, "goto" => "end"} | acc]
        pos_str ->
          case Integer.parse(pos_str) do
            {pos, _} -> [%{"branch" => branch, "goto" => pos} | acc]
            :error -> acc
          end
      end
    end)
    |> Enum.reverse()
  end

  defp merge_resilience_config(config, params) do
    config =
      case params["step_on_circuit_open"] do
        "halt" -> Map.drop(config, ["on_circuit_open", "fallback_skill"])
        "skip" -> config |> Map.put("on_circuit_open", "skip") |> Map.drop(["fallback_skill"])
        "fallback" ->
          config
          |> Map.put("on_circuit_open", "fallback")
          |> then(fn c ->
            case blank_to_nil(params["step_fallback_skill"]) do
              nil -> c
              skill -> Map.put(c, "fallback_skill", skill)
            end
          end)
        _ -> config
      end

    case params["step_on_missing_skill"] do
      "skip" -> Map.put(config, "on_missing_skill", "skip")
      _ -> Map.delete(config, "on_missing_skill")
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

  defp workflow_uses_resources?(workflow) do
    Enum.any?(workflow.steps, fn step -> skill_uses_resources?(step.skill) end)
  end

  defp skill_uses_resources?("rss_collector"), do: true
  defp skill_uses_resources?("rss_fetch"), do: true
  defp skill_uses_resources?("web_automation"), do: true
  defp skill_uses_resources?(_), do: false

  # --- Skill metadata (delegated to SkillRegistry) ---

  defp skill_meta(skill_name), do: SkillRegistry.get_skill_meta(skill_name)

  defp skill_has_field?(skill, field), do: field in skill_meta(skill).step_fields

  defp skill_config_hint(skill), do: skill_meta(skill).config_hint

  defp skill_config_scaffold(skill) do
    case skill_meta(skill).config_scaffold do
      scaffold when scaffold == %{} -> "{}"
      scaffold -> Jason.encode!(scaffold, pretty: true)
    end
  end

  defp skill_scaffolds(skill) do
    Enum.into(skill_meta(skill).config_presets, %{}, fn {name, data} -> {name, Jason.encode!(data, pretty: true)} end)
  end

  defp skill_has_scaffolds?(skill), do: skill_meta(skill).config_presets != %{}

  defp skill_prompt_scaffolds(skill), do: skill_meta(skill).prompt_presets

  defp skill_has_prompt_scaffolds?(skill), do: skill_meta(skill).prompt_presets != %{}

  defp skill_help(skill) do
    meta = skill_meta(skill)
    %{prompt: meta.prompt_help, config: meta.config_help}
  end

  defp tip(assigns) do
    ~H"""
    <span class="relative inline-block ml-1 group">
      <span class="inline-flex items-center justify-center w-4 h-4 rounded-full bg-gray-700 text-gray-400 text-[10px] cursor-help group-hover:bg-yellow-400 group-hover:text-black transition">?</span>
      <span class="absolute bottom-full left-0 mb-2 px-3 py-2 bg-yellow-400 text-black text-xs rounded shadow-lg w-64 hidden group-hover:block z-50">
        {@text}
      </span>
    </span>
    """
  end

  defp workflow_cluster_role(workflow_id) do
    steps = load_steps(workflow_id)
    skills = Enum.map(steps, & &1.skill)
    first_skill = List.first(steps) && List.first(steps).skill

    cond do
      first_skill == "receive_from_workflow" and "send_to_workflow" in skills -> :bridge
      first_skill == "receive_from_workflow" -> :receiver
      "send_to_workflow" in skills -> :sender
      true -> :local
    end
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

  defp cluster_node_names do
    Enum.uniq([to_string(node()) | Enum.map(AlexClaw.Cluster.list_nodes(), & &1.name)])
  end

  defp filter_workflows(workflows, ""), do: workflows
  defp filter_workflows(workflows, nil), do: workflows

  defp filter_workflows(workflows, filter) do
    filter = String.downcase(filter)
    Enum.filter(workflows, fn wf -> String.contains?(String.downcase(wf.name), filter) end)
  end

  defp upload_error_message(:too_large), do: "File too large (max 1 MB)"
  defp upload_error_message(:not_accepted), do: "Only .json files accepted"
  defp upload_error_message(err), do: "Error: #{inspect(err)}"
end
