defmodule AlexClaw.Workflows do
  @moduledoc """
  Context for managing workflows, steps, resource assignments, and runs.
  """
  import Ecto.Query
  alias AlexClaw.Repo
  alias AlexClaw.Workflows.{Workflow, WorkflowStep, WorkflowResource, WorkflowRun}

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

  @doc "List workflows that have a schedule defined and are enabled."
  @spec list_scheduled_workflows() :: [Workflow.t()]
  def list_scheduled_workflows do
    Workflow
    |> where([w], w.enabled == true and not is_nil(w.schedule) and w.schedule != "")
    |> Repo.all()
  end
end
