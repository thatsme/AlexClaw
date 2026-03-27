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
          prompt_template: step.prompt_template
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
