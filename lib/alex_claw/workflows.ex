defmodule AlexClaw.Workflows do
  @moduledoc """
  Context for managing workflows, steps, resource assignments, and runs.
  """
  import Ecto.Query
  alias AlexClaw.Repo
  alias AlexClaw.Workflows.{Workflow, WorkflowStep, WorkflowResource, WorkflowRun, SkillOutcome}

  # --- Workflows ---

  @spec list_workflows() :: [Workflow.t()]
  def list_workflows do
    Workflow
    |> order_by(:name)
    |> Repo.all()
  end

  @spec get_workflow(integer()) :: {:ok, Workflow.t()} | {:error, :not_found}
  def get_workflow(id) do
    case Repo.get(Workflow, id) do
      nil -> {:error, :not_found}
      workflow -> {:ok, Repo.preload(workflow, [:steps, :resources, :workflow_resources])}
    end
  end

  @spec get_workflow!(integer()) :: Workflow.t()
  def get_workflow!(id) do
    Workflow
    |> Repo.get!(id)
    |> Repo.preload([:steps, :resources, :workflow_resources])
  end

  @spec create_workflow(map()) :: {:ok, Workflow.t()} | {:error, Ecto.Changeset.t()}
  def create_workflow(attrs) do
    %Workflow{}
    |> Workflow.changeset(attrs)
    |> Repo.insert()
  end

  @spec update_workflow(Workflow.t(), map()) :: {:ok, Workflow.t()} | {:error, Ecto.Changeset.t()}
  def update_workflow(%Workflow{} = workflow, attrs) do
    workflow
    |> Workflow.changeset(attrs)
    |> Repo.update()
  end

  @spec delete_workflow(Workflow.t()) :: {:ok, Workflow.t()} | {:error, Ecto.Changeset.t()}
  def delete_workflow(%Workflow{} = workflow) do
    Repo.delete(workflow)
  end

  @spec duplicate_workflow(Workflow.t()) :: {:ok, Workflow.t()} | {:error, Ecto.Changeset.t()}
  def duplicate_workflow(%Workflow{} = workflow) do
    workflow = Repo.preload(workflow, [:steps, :workflow_resources])

    Repo.transaction(fn ->
      {:ok, new_wf} =
        %Workflow{}
        |> Workflow.changeset(%{
          name: workflow.name <> " (copy)",
          description: workflow.description,
          schedule: nil,
          enabled: false,
          default_provider: workflow.default_provider
        })
        |> Repo.insert()

      Enum.each(workflow.steps, fn step ->
        %WorkflowStep{}
        |> WorkflowStep.changeset(%{
          workflow_id: new_wf.id,
          name: step.name,
          skill: step.skill,
          position: step.position,
          config: step.config,
          llm_tier: step.llm_tier,
          llm_model: step.llm_model,
          prompt_template: step.prompt_template,
          input_from: step.input_from,
          routes: step.routes
        })
        |> Repo.insert!()
      end)

      Enum.each(workflow.workflow_resources, fn wr ->
        %WorkflowResource{}
        |> WorkflowResource.changeset(%{
          workflow_id: new_wf.id,
          resource_id: wr.resource_id,
          role: wr.role
        })
        |> Repo.insert!()
      end)

      new_wf
    end)
  end

  # --- Export / Import ---

  @doc "Serialize a workflow definition (with steps and resource references) to a JSON-friendly map."
  @spec export_workflow(Workflow.t()) :: map()
  def export_workflow(%Workflow{} = workflow) do
    workflow = Repo.preload(workflow, [:steps, :workflow_resources, :resources])

    %{
      "version" => 1,
      "workflow" => %{
        "name" => workflow.name,
        "description" => workflow.description,
        "enabled" => workflow.enabled,
        "schedule" => workflow.schedule,
        "default_provider" => workflow.default_provider,
        "node" => workflow.node,
        "metadata" => workflow.metadata
      },
      "steps" =>
        workflow.steps
        |> Enum.sort_by(& &1.position)
        |> Enum.map(fn step ->
          %{
            "position" => step.position,
            "name" => step.name,
            "skill" => step.skill,
            "llm_tier" => step.llm_tier,
            "llm_model" => step.llm_model,
            "prompt_template" => step.prompt_template,
            "config" => step.config,
            "input_from" => step.input_from,
            "routes" => step.routes
          }
        end),
      "resources" =>
        Enum.map(workflow.workflow_resources, fn wr ->
          resource = Enum.find(workflow.resources, &(&1.id == wr.resource_id))

          %{
            "name" => resource && resource.name,
            "type" => resource && resource.type,
            "url" => resource && resource.url,
            "content" => resource && resource.content,
            "metadata" => resource && resource.metadata,
            "tags" => resource && resource.tags,
            "enabled" => resource && resource.enabled,
            "role" => wr.role
          }
        end)
    }
  end

  @doc "Import a workflow from a JSON-decoded map. Returns {:ok, workflow, warnings} or {:error, message}."
  @spec import_workflow(map()) :: {:ok, Workflow.t(), [String.t()]} | {:error, String.t()}
  def import_workflow(data) when is_map(data) do
    with :ok <- validate_import_structure(data) do
      do_import(data)
    end
  end

  def import_workflow(_), do: {:error, "Invalid format: expected a JSON object"}

  defp validate_import_structure(data) do
    cond do
      data["version"] != 1 ->
        {:error, "Unsupported or missing version (expected 1, got #{inspect(data["version"])})"}

      not is_map(data["workflow"]) ->
        {:error, "Missing or invalid \"workflow\" field"}

      not is_binary(data["workflow"]["name"]) or data["workflow"]["name"] == "" ->
        {:error, "Workflow name is required"}

      not is_list(data["steps"]) ->
        {:error, "Missing or invalid \"steps\" field"}

      true ->
        :ok
    end
  end

  defp do_import(data) do
    wf_attrs = data["workflow"]
    name = resolve_import_name(wf_attrs["name"])

    result =
      Repo.transaction(fn ->
        case %Workflow{}
             |> Workflow.changeset(%{
               name: name,
               description: wf_attrs["description"],
               enabled: wf_attrs["enabled"] || false,
               schedule: wf_attrs["schedule"],
               default_provider: wf_attrs["default_provider"],
               node: wf_attrs["node"],
               metadata: wf_attrs["metadata"] || %{}
             })
             |> Repo.insert() do
          {:ok, new_wf} ->
            insert_imported_steps(new_wf, data["steps"])
            warnings = link_imported_resources(new_wf, data["resources"] || [])
            {new_wf, warnings}

          {:error, changeset} ->
            Repo.rollback(changeset_to_message(changeset))
        end
      end)

    case result do
      {:ok, {workflow, warnings}} -> {:ok, workflow, warnings}
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, changeset} -> {:error, changeset_to_message(changeset)}
    end
  end

  defp resolve_import_name(base_name) do
    case Repo.get_by(Workflow, name: base_name) do
      nil ->
        base_name

      _exists ->
        1
        |> Stream.iterate(&(&1 + 1))
        |> Enum.find(fn n ->
          is_nil(Repo.get_by(Workflow, name: "#{base_name} (imported #{n})"))
        end)
        |> then(&"#{base_name} (imported #{&1})")
    end
  end

  defp insert_imported_steps(workflow, steps) do
    Enum.each(steps, fn step ->
      case %WorkflowStep{}
           |> WorkflowStep.changeset(%{
             workflow_id: workflow.id,
             position: step["position"],
             name: step["name"],
             skill: step["skill"],
             llm_tier: step["llm_tier"],
             llm_model: step["llm_model"],
             prompt_template: step["prompt_template"],
             config: step["config"] || %{},
             input_from: step["input_from"],
             routes: step["routes"] || []
           })
           |> Repo.insert() do
        {:ok, _} -> :ok
        {:error, changeset} -> Repo.rollback(changeset_to_message(changeset))
      end
    end)
  end

  defp link_imported_resources(workflow, resources) do
    alias AlexClaw.Resources.Resource

    resources
    |> Enum.reduce([], fn res, warnings ->
      resource = find_or_create_resource(res)

      case resource do
        {:ok, resource, :found} ->
          link_resource(workflow, resource, res["role"])
          warnings

        {:ok, resource, :created} ->
          link_resource(workflow, resource, res["role"])
          ["Resource '#{res["name"]}' created" | warnings]

        {:error, reason} ->
          ["Resource '#{res["name"]}' failed to create: #{reason}" | warnings]
      end
    end)
    |> Enum.reverse()
  end

  defp find_or_create_resource(res) do
    alias AlexClaw.Resources.Resource

    query =
      Resource
      |> where([r], r.name == ^(res["name"] || ""))
      |> limit(1)

    query =
      case res["url"] do
        nil -> where(query, [r], is_nil(r.url))
        url -> where(query, [r], r.url == ^url)
      end

    case Repo.one(query) do
      nil ->
        case %Resource{}
             |> Resource.changeset(%{
               name: res["name"],
               type: res["type"],
               url: res["url"],
               content: res["content"],
               metadata: res["metadata"] || %{},
               tags: res["tags"] || [],
               enabled: res["enabled"] != false
             })
             |> Repo.insert() do
          {:ok, resource} -> {:ok, resource, :created}
          {:error, changeset} -> {:error, changeset_to_message(changeset)}
        end

      resource ->
        {:ok, resource, :found}
    end
  end

  defp link_resource(workflow, resource, role) do
    %WorkflowResource{}
    |> WorkflowResource.changeset(%{
      workflow_id: workflow.id,
      resource_id: resource.id,
      role: role || "input"
    })
    |> Repo.insert()
  end

  defp changeset_to_message(%Ecto.Changeset{} = changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
          to_string(Keyword.get(opts, String.to_existing_atom(key), key))
        end)
      end)

    Enum.map_join(errors, "; ", fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)
  end

  defp changeset_to_message(other), do: inspect(other)

  # --- Steps ---

  @spec add_step(Workflow.t(), map()) :: {:ok, WorkflowStep.t()} | {:error, Ecto.Changeset.t()}
  def add_step(%Workflow{} = workflow, attrs) do
    next_position =
      WorkflowStep
      |> where([s], s.workflow_id == ^workflow.id)
      |> select([s], coalesce(max(s.position), 0))
      |> Repo.one()
      |> Kernel.+(1)

    attrs = Map.put(attrs, :workflow_id, workflow.id)
    attrs = Map.put_new(attrs, :position, next_position)

    %WorkflowStep{}
    |> WorkflowStep.changeset(attrs)
    |> Repo.insert()
  end

  @spec update_step(WorkflowStep.t(), map()) :: {:ok, WorkflowStep.t()} | {:error, Ecto.Changeset.t()}
  def update_step(%WorkflowStep{} = step, attrs) do
    step
    |> WorkflowStep.changeset(attrs)
    |> Repo.update()
  end

  @spec remove_step(WorkflowStep.t()) :: {:ok, WorkflowStep.t()} | {:error, Ecto.Changeset.t()}
  def remove_step(%WorkflowStep{} = step) do
    Repo.delete(step)
  end

  @spec reorder_steps(Workflow.t(), [integer()]) :: {:ok, any()} | {:error, any()}
  def reorder_steps(%Workflow{} = workflow, step_ids) when is_list(step_ids) do
    Repo.transaction(fn ->
      step_ids
      |> Enum.with_index(1)
      |> Enum.each(fn {step_id, position} ->
        WorkflowStep
        |> where([s], s.id == ^step_id and s.workflow_id == ^workflow.id)
        |> Repo.update_all(set: [position: position])
      end)
    end)
  end

  # --- Resource Assignment ---

  @spec assign_resource(Workflow.t(), integer(), String.t()) :: {:ok, WorkflowResource.t()} | {:error, Ecto.Changeset.t()}
  def assign_resource(%Workflow{} = workflow, resource_id, role \\ "input") do
    %WorkflowResource{}
    |> WorkflowResource.changeset(%{workflow_id: workflow.id, resource_id: resource_id, role: role})
    |> Repo.insert()
  end

  @spec unassign_resource(Workflow.t(), integer()) :: {non_neg_integer(), nil | [any()]}
  def unassign_resource(%Workflow{} = workflow, resource_id) do
    WorkflowResource
    |> where([wr], wr.workflow_id == ^workflow.id and wr.resource_id == ^resource_id)
    |> Repo.delete_all()
  end

  # --- Runs ---

  @spec create_run(Workflow.t(), map()) :: {:ok, WorkflowRun.t()} | {:error, Ecto.Changeset.t()}
  def create_run(%Workflow{} = workflow, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{workflow_id: workflow.id, status: "running", started_at: DateTime.utc_now()},
        attrs
      )

    %WorkflowRun{}
    |> WorkflowRun.changeset(attrs)
    |> Repo.insert()
  end

  @spec update_run(WorkflowRun.t(), map()) :: {:ok, WorkflowRun.t()} | {:error, Ecto.Changeset.t()}
  def update_run(%WorkflowRun{} = run, attrs) do
    run
    |> WorkflowRun.changeset(attrs)
    |> Repo.update()
  end

  @spec list_runs(integer()) :: [WorkflowRun.t()]
  def list_runs(workflow_id) do
    WorkflowRun
    |> where([r], r.workflow_id == ^workflow_id)
    |> order_by([r], desc: r.started_at)
    |> Repo.all()
  end

  @spec get_run(integer()) :: {:ok, WorkflowRun.t()} | {:error, :not_found}
  def get_run(id) do
    case Repo.get(WorkflowRun, id) do
      nil -> {:error, :not_found}
      run -> {:ok, run}
    end
  end

  @spec get_run!(integer()) :: WorkflowRun.t()
  def get_run!(id), do: Repo.get!(WorkflowRun, id)

  @spec clear_runs(integer()) :: {non_neg_integer(), nil | [any()]}
  def clear_runs(workflow_id) do
    WorkflowRun
    |> where([r], r.workflow_id == ^workflow_id)
    |> Repo.delete_all()
  end

  @doc "Aggregate run statistics for today (UTC). Returns counts by status."
  @spec run_stats_today() :: %{total: non_neg_integer(), completed: non_neg_integer(), failed: non_neg_integer(), running: non_neg_integer()}
  def run_stats_today do
    today_start = DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")

    results =
      WorkflowRun
      |> where([r], r.started_at >= ^today_start)
      |> group_by([r], r.status)
      |> select([r], {r.status, count(r.id)})
      |> Repo.all()
      |> Map.new()

    %{
      total: Enum.sum(Map.values(results)),
      completed: Map.get(results, "completed", 0),
      failed: Map.get(results, "failed", 0),
      running: Map.get(results, "running", 0)
    }
  end

  @spec list_active_runs() :: [map()]
  def list_active_runs, do: AlexClaw.Workflows.Registry.list_active()

  @spec cancel_run(integer()) :: :ok | {:error, :not_found}
  def cancel_run(run_id), do: AlexClaw.Workflows.Registry.cancel(run_id)

  # --- Skill Outcomes ---

  @doc "Record a skill execution outcome. Called by the executor after each step."
  @spec record_outcome(map()) :: {:ok, SkillOutcome.t()} | {:error, Ecto.Changeset.t()}
  def record_outcome(attrs) do
    %SkillOutcome{}
    |> SkillOutcome.changeset(attrs)
    |> Repo.insert()
  end

  @doc "List outcomes for a given skill, most recent first. Opts: :limit, :quality"
  @spec list_outcomes(String.t(), keyword()) :: [SkillOutcome.t()]
  def list_outcomes(skill_name, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    quality = Keyword.get(opts, :quality)

    query =
      SkillOutcome
      |> where([o], o.skill_name == ^skill_name)
      |> order_by([o], desc: o.inserted_at)
      |> limit(^limit)

    query =
      if quality do
        where(query, [o], o.result_quality == ^quality)
      else
        query
      end

    Repo.all(query)
  end

  @doc "Aggregate outcome stats for a skill: total, thumbs_up, thumbs_down counts."
  @spec outcome_stats(String.t()) :: %{total: non_neg_integer(), thumbs_up: non_neg_integer(), thumbs_down: non_neg_integer()}
  def outcome_stats(skill_name) do
    results =
      SkillOutcome
      |> where([o], o.skill_name == ^skill_name)
      |> group_by([o], o.result_quality)
      |> select([o], {o.result_quality, count(o.id)})
      |> Repo.all()
      |> Map.new()

    %{
      total: Enum.sum(Map.values(results)),
      thumbs_up: Map.get(results, "thumbs_up", 0),
      thumbs_down: Map.get(results, "thumbs_down", 0)
    }
  end

  @doc "Annotate an existing outcome with user quality rating and optional feedback."
  @spec annotate_outcome(integer(), String.t(), String.t() | nil) :: {:ok, SkillOutcome.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def annotate_outcome(outcome_id, quality, feedback \\ nil) do
    case Repo.get(SkillOutcome, outcome_id) do
      nil ->
        {:error, :not_found}

      outcome ->
        attrs = %{result_quality: quality}
        attrs = if feedback, do: Map.put(attrs, :user_feedback, feedback), else: attrs

        outcome
        |> SkillOutcome.changeset(attrs)
        |> Repo.update()
    end
  end

  @doc "List all outcomes for a given workflow run."
  @spec list_run_outcomes(integer()) :: [SkillOutcome.t()]
  def list_run_outcomes(run_id) do
    SkillOutcome
    |> where([o], o.workflow_run_id == ^run_id)
    |> order_by([o], o.step_position)
    |> Repo.all()
  end

  @doc "List workflows that have a schedule defined and are enabled."
  @spec list_scheduled_workflows() :: [Workflow.t()]
  def list_scheduled_workflows do
    node_name = to_string(node())

    Workflow
    |> where([w], w.enabled == true and not is_nil(w.schedule) and w.schedule != "")
    |> where([w], is_nil(w.node) or w.node == "" or w.node == ^node_name)
    |> Repo.all()
  end
end
