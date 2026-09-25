defmodule AlexClaw.Workflows do
  @moduledoc """
  Context for managing workflows, steps, resource assignments, and runs.
  """
  import Ecto.Query
  alias AlexClaw.Repo

  alias AlexClaw.Workflows.{
    SkillOutcome,
    SkillRegistry,
    StepReferences,
    Workflow,
    WorkflowResource,
    WorkflowRun,
    WorkflowStep
  }

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
      # A copy is a copy, protection and node included; it does not start
      # running on its own, so no schedule and disabled.
      new_wf =
        %Workflow{}
        |> Workflow.changeset(%{
          name: copy_name(workflow.name),
          description: workflow.description,
          schedule: nil,
          enabled: false,
          default_provider: workflow.default_provider,
          node: workflow.node,
          metadata: workflow.metadata
        })
        |> Repo.insert()
        |> inserted_or_rollback()

      new_ids = Map.new(workflow.steps, &{&1.id, copy_step(&1, new_wf.id).id})

      Enum.each(workflow.workflow_resources, fn wr ->
        %WorkflowResource{}
        |> WorkflowResource.changeset(%{
          workflow_id: new_wf.id,
          resource_id: wr.resource_id,
          role: wr.role
        })
        |> Repo.insert!()
      end)

      remap_secret_marks(new_wf, new_ids)
    end)
  end

  defp inserted_or_rollback({:ok, record}), do: record
  defp inserted_or_rollback({:error, changeset}), do: Repo.rollback(changeset)

  defp copy_step(step, workflow_id) do
    %WorkflowStep{}
    |> WorkflowStep.changeset(%{
      workflow_id: workflow_id,
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
  end

  # "<name> (copy)", then "(copy 2)", "(copy 3)"…: the first that is free.
  defp copy_name(name), do: free_copy_name(name, 1)

  defp free_copy_name(name, n) do
    candidate = if n == 1, do: "#{name} (copy)", else: "#{name} (copy #{n})"

    if Repo.exists?(from(w in Workflow, where: w.name == ^candidate)),
      do: free_copy_name(name, n + 1),
      else: candidate
  end

  # The "needs secrets" marks are keyed by step id; the copy's steps have new ids.
  defp remap_secret_marks(%Workflow{metadata: %{"steps_needing_secrets" => marks}} = wf, new_ids)
       when is_map(marks) and map_size(marks) > 0 do
    remapped = Map.new(marks, fn {id, keys} -> {new_step_id(id, new_ids), keys} end)

    wf
    |> Workflow.changeset(%{metadata: Map.put(wf.metadata, "steps_needing_secrets", remapped)})
    |> Repo.update!()
  end

  defp remap_secret_marks(wf, _new_ids), do: wf

  defp new_step_id(id, new_ids) do
    case Integer.parse(to_string(id)) do
      {old, ""} -> to_string(Map.get(new_ids, old, old))
      _ -> id
    end
  end

  # --- Export / Import ---

  # A shared workflow file carries no credential: every config key a skill
  # declares secret is exported as this placeholder, string by string. An
  # import leaves those values empty and marks the step as needing secrets in
  # the workflow's metadata (keyed by step id, so it adds no column: a new
  # column would make the previous release's data exports unrestorable).
  @secret_placeholder "<secret not exported>"
  @needs_secrets "steps_needing_secrets"

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
        "metadata" => Map.delete(workflow.metadata || %{}, @needs_secrets)
      },
      "steps" => workflow.steps |> Enum.sort_by(& &1.position) |> Enum.map(&export_step/1),
      "resources" =>
        Enum.map(workflow.workflow_resources, fn wr ->
          workflow.resources
          |> Enum.find(&(&1.id == wr.resource_id))
          |> export_resource()
          |> Map.put("role", wr.role)
        end)
    }
  end

  defp export_step(step) do
    %{
      "position" => step.position,
      "name" => step.name,
      "skill" => step.skill,
      "llm_tier" => step.llm_tier,
      "llm_model" => step.llm_model,
      "prompt_template" => step.prompt_template,
      "config" => redacted(step.config, @secret_placeholder),
      "input_from" => step.input_from,
      "routes" => step.routes
    }
  end

  @resource_fields ~w(name type url content metadata tags enabled)a

  defp export_resource(nil), do: Map.new(@resource_fields, &{Atom.to_string(&1), nil})

  defp export_resource(resource),
    do: Map.new(@resource_fields, &{Atom.to_string(&1), Map.fetch!(resource, &1)})

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
        %Workflow{}
        |> Workflow.changeset(imported_attrs(wf_attrs, name))
        |> Repo.insert()
        |> imported(data)
      end)

    case result do
      {:ok, {workflow, warnings}} -> {:ok, workflow, warnings}
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, changeset} -> {:error, changeset_to_message(changeset)}
    end
  end

  # An imported workflow is always disabled, whatever the file says: it runs
  # nothing, on a schedule or otherwise, until someone enables it through the
  # gated save.
  defp imported_attrs(wf_attrs, name) do
    %{
      name: name,
      description: wf_attrs["description"],
      enabled: false,
      schedule: wf_attrs["schedule"],
      default_provider: wf_attrs["default_provider"],
      node: wf_attrs["node"],
      metadata: Map.delete(wf_attrs["metadata"] || %{}, @needs_secrets)
    }
  end

  defp imported({:ok, new_wf}, data) do
    new_wf |> insert_imported_steps(data["steps"]) |> mark_needing_secrets(new_wf)
    {new_wf, link_imported_resources(new_wf, data["resources"] || [])}
  end

  defp imported({:error, changeset}, _data), do: Repo.rollback(changeset_to_message(changeset))

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
    Enum.map(steps, fn step ->
      {config, missing} = unredacted(step["config"] || %{})

      case %WorkflowStep{}
           |> WorkflowStep.changeset(%{
             workflow_id: workflow.id,
             position: step["position"],
             name: step["name"],
             skill: step["skill"],
             llm_tier: step["llm_tier"],
             llm_model: step["llm_model"],
             prompt_template: step["prompt_template"],
             config: config,
             input_from: step["input_from"],
             routes: step["routes"] || []
           })
           |> Repo.insert() do
        {:ok, inserted} -> {inserted.id, missing}
        {:error, changeset} -> Repo.rollback(changeset_to_message(changeset))
      end
    end)
  end

  defp mark_needing_secrets(step_results, workflow) do
    marks = for {id, [_ | _] = keys} <- step_results, into: %{}, do: {to_string(id), keys}
    if marks != %{}, do: put_marks(workflow, marks)
    :ok
  end

  defp put_marks(workflow, marks) do
    metadata = workflow.metadata || %{}

    metadata =
      if marks == %{},
        do: Map.delete(metadata, @needs_secrets),
        else: Map.put(metadata, @needs_secrets, marks)

    workflow |> Workflow.changeset(%{metadata: metadata}) |> Repo.update!()
  end

  # Every value under a key some skill declares secret, string by string, is
  # replaced by `placeholder`: an export's, or a run definition's.
  defp redacted(nil, _placeholder), do: nil

  defp redacted(config, placeholder) do
    secret = SkillRegistry.secret_config_keys()
    Map.new(config, fn {k, v} -> {k, redact_if(to_string(k) in secret, v, placeholder)} end)
  end

  defp redact_if(false, value, _placeholder), do: value
  defp redact_if(true, value, placeholder), do: redact(value, placeholder)

  defp redact(value, _placeholder) when value in [nil, ""], do: value

  defp redact(value, placeholder) when is_map(value),
    do: Map.new(value, fn {k, v} -> {k, redact(v, placeholder)} end)

  defp redact(value, placeholder) when is_list(value),
    do: Enum.map(value, &redact(&1, placeholder))

  defp redact(_value, placeholder), do: placeholder

  # The config with every placeholder emptied, and the declared keys that held one.
  defp unredacted(config) when is_map(config) do
    secret = SkillRegistry.secret_config_keys()
    missing = for {k, v} <- config, to_string(k) in secret, placeholder?(v), do: to_string(k)

    {Map.new(config, fn {k, v} -> {k, empty_if(to_string(k) in secret, v)} end),
     Enum.sort(missing)}
  end

  defp unredacted(config), do: {config, []}

  defp empty_if(true, value), do: emptied(value)
  defp empty_if(false, value), do: value

  defp placeholder?(@secret_placeholder), do: true

  defp placeholder?(value) when is_map(value),
    do: Enum.any?(value, fn {_k, v} -> placeholder?(v) end)

  defp placeholder?(value) when is_list(value), do: Enum.any?(value, &placeholder?/1)
  defp placeholder?(_value), do: false

  defp emptied(@secret_placeholder), do: ""
  defp emptied(value) when is_map(value), do: Map.new(value, fn {k, v} -> {k, emptied(v)} end)
  defp emptied(value) when is_list(value), do: Enum.map(value, &emptied/1)
  defp emptied(value), do: value

  @doc """
  The steps of `workflow` imported without their secrets: step id => the
  config keys still to fill in. A step leaves the list once those keys hold
  values again (`update_step/2`).
  """
  @spec steps_needing_secrets(Workflow.t()) :: %{integer() => [String.t()]}
  def steps_needing_secrets(%Workflow{metadata: metadata}) do
    for {id, keys} <- Map.get(metadata || %{}, @needs_secrets, %{}),
        {n, ""} <- [Integer.parse(to_string(id))],
        into: %{},
        do: {n, keys}
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

    Resource
    |> where([r], r.name == ^(res["name"] || ""))
    |> limit(1)
    |> match_url(res["url"])
    |> Repo.one()
    |> found_or_create(res)
  end

  defp match_url(query, nil), do: where(query, [r], is_nil(r.url))
  defp match_url(query, url), do: where(query, [r], r.url == ^url)

  defp found_or_create(nil, res), do: create_resource(res)
  defp found_or_create(resource, _res), do: {:ok, resource, :found}

  defp create_resource(res) do
    alias AlexClaw.Resources.Resource

    %Resource{}
    |> Resource.changeset(%{
      name: res["name"],
      type: res["type"],
      url: res["url"],
      content: res["content"],
      metadata: res["metadata"] || %{},
      tags: res["tags"] || [],
      enabled: res["enabled"] != false
    })
    |> Repo.insert()
    |> created()
  end

  defp created({:ok, resource}), do: {:ok, resource, :created}
  defp created({:error, changeset}), do: {:error, changeset_to_message(changeset)}

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

  @spec update_step(WorkflowStep.t(), map()) ::
          {:ok, WorkflowStep.t()} | {:error, Ecto.Changeset.t()}
  def update_step(%WorkflowStep{} = step, attrs) do
    with {:ok, updated} <- step |> WorkflowStep.changeset(attrs) |> Repo.update() do
      clear_secret_mark(updated)
      {:ok, updated}
    end
  end

  # A step imported without its secrets stops being marked once every key it
  # was missing holds a value.
  defp clear_secret_mark(step) do
    workflow = Repo.get!(Workflow, step.workflow_id)
    missing = Map.get(steps_needing_secrets(workflow), step.id, [])
    unmark(missing != [] and Enum.all?(missing, &filled?(step.config[&1])), workflow, step.id)
  end

  defp unmark(false, _workflow, _id), do: :ok

  defp unmark(true, workflow, id) do
    marks = workflow.metadata |> Map.get(@needs_secrets, %{}) |> Map.delete(to_string(id))
    put_marks(workflow, marks)
  end

  defp filled?(value) when value in [nil, ""], do: false

  defp filled?(value) when is_map(value),
    do: value != %{} and Enum.all?(value, fn {_k, v} -> filled?(v) end)

  defp filled?(value) when is_list(value), do: Enum.all?(value, &filled?/1)
  defp filled?(_value), do: true

  @doc """
  Remove `step`. The remaining steps are numbered 1..n in order, and every route
  (`goto`) and `input_from` pointing at them follows, in the same
  transaction. A step that a route or `input_from` of another step points to
  is refused, `{:error, {:referenced_by, names}}`, naming those steps: nothing
  is rewired to something else, and nothing is left dangling.
  """
  @spec remove_step(WorkflowStep.t()) ::
          {:ok, WorkflowStep.t()} | {:error, {:referenced_by, [String.t()]} | term()}
  def remove_step(%WorkflowStep{} = step) do
    Repo.transaction(fn ->
      others = Enum.reject(steps_of(step.workflow_id), &(&1.id == step.id))
      removed(Enum.filter(others, &points_to?(&1, step.position)), step, others)
    end)
  end

  # The remaining steps are numbered 1..n in their order, which also closes
  # gaps an earlier removal left; references follow.
  defp removed([], step, others) do
    deleted = Repo.delete!(step)

    moved =
      others
      |> Enum.sort_by(& &1.position)
      |> Enum.with_index(1)
      |> Map.new(fn {other, position} -> {other.position, position} end)

    renumber(others, moved)
    deleted
  end

  defp removed(pointing, _step, _others),
    do: Repo.rollback({:referenced_by, Enum.map(pointing, & &1.name)})

  defp points_to?(step, position),
    do: step.input_from == position or Enum.any?(step.routes || [], &(&1["goto"] == position))

  defp steps_of(workflow_id),
    do: WorkflowStep |> where([s], s.workflow_id == ^workflow_id) |> Repo.all()

  # Positions are unique per workflow and checked on every statement, so the
  # steps are first parked at negative positions (their ids, negated), then
  # given their new ones: no update meets a position another step still holds.
  defp renumber(steps, moved) do
    Enum.each(steps, &park/1)
    Enum.each(steps, &rewrite_step(&1, moved[&1.position], moved))
  end

  defp park(step) do
    WorkflowStep
    |> where([s], s.id == ^step.id)
    |> Repo.update_all(set: [position: -step.id])
  end

  # The step at `position`, its routes and input_from rewritten through `moved`
  # (old position => new position). "end", "default" and anything that is not
  # a position are left as they are.
  defp rewrite_step(step, position, moved) do
    WorkflowStep
    |> where([s], s.id == ^step.id)
    |> Repo.update_all(
      set: [
        position: position,
        routes: Enum.map(step.routes || [], &StepReferences.moved_route(&1, moved)),
        input_from: StepReferences.moved_position(step.input_from, moved)
      ]
    )
  end

  @doc """
  Put the steps of `workflow` in the order of `step_ids`. Every route (`goto`)
  and `input_from` is rewritten in the same transaction, so each still points
  at the same step.
  """
  @spec reorder_steps(Workflow.t(), [integer()]) :: {:ok, any()} | {:error, any()}
  def reorder_steps(%Workflow{} = workflow, step_ids) when is_list(step_ids) do
    Repo.transaction(fn ->
      steps = steps_of(workflow.id)
      new_positions = step_ids |> Enum.with_index(1) |> Map.new()
      moved = Map.new(steps, &{&1.position, Map.get(new_positions, &1.id, &1.position)})
      renumber(steps, moved)
    end)
  end

  # --- Resource Assignment ---

  @spec assign_resource(Workflow.t(), integer(), String.t()) ::
          {:ok, WorkflowResource.t()} | {:error, Ecto.Changeset.t()}
  def assign_resource(%Workflow{} = workflow, resource_id, role \\ "input") do
    %WorkflowResource{}
    |> WorkflowResource.changeset(%{
      workflow_id: workflow.id,
      resource_id: resource_id,
      role: role
    })
    |> Repo.insert()
  end

  @spec unassign_resource(Workflow.t(), integer()) :: {non_neg_integer(), nil | [any()]}
  def unassign_resource(%Workflow{} = workflow, resource_id) do
    WorkflowResource
    |> where([wr], wr.workflow_id == ^workflow.id and wr.resource_id == ^resource_id)
    |> Repo.delete_all()
  end

  # --- Runs ---

  @doc """
  The definition a run records when it starts: each step's position, name,
  skill, config, routes and input_from, as they are now. Secret config values
  are replaced by `"<secret>"`, so a run's history never stores a credential.
  `workflow` must have its steps loaded.
  """
  @spec run_definition(Workflow.t()) :: map()
  def run_definition(%Workflow{steps: steps}) when is_list(steps) do
    %{"steps" => steps |> Enum.sort_by(& &1.position) |> Enum.map(&step_definition/1)}
  end

  defp step_definition(step) do
    %{
      "position" => step.position,
      "name" => step.name,
      "skill" => step.skill,
      "config" => redacted(step.config || %{}, "<secret>"),
      "routes" => step.routes || [],
      "input_from" => step.input_from
    }
  end

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

  @spec update_run(WorkflowRun.t(), map()) ::
          {:ok, WorkflowRun.t()} | {:error, Ecto.Changeset.t()}
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
  @spec run_stats_today() :: %{
          total: non_neg_integer(),
          completed: non_neg_integer(),
          recovered: non_neg_integer(),
          failed: non_neg_integer(),
          running: non_neg_integer()
        }
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
      recovered: Map.get(results, "recovered", 0),
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
  @spec outcome_stats(String.t()) :: %{
          total: non_neg_integer(),
          thumbs_up: non_neg_integer(),
          thumbs_down: non_neg_integer()
        }
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
  @spec annotate_outcome(integer(), String.t(), String.t() | nil) ::
          {:ok, SkillOutcome.t()} | {:error, :not_found | Ecto.Changeset.t()}
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
