defmodule AlexClaw.MCP.ResourceProvider do
  @moduledoc """
  Maps AlexClaw data to MCP resource templates.

  Registers URI templates for browsing AlexClaw's data stores
  (resources, knowledge, memory, workflows, runs, config) and
  resolves `resources/read` requests to the appropriate context module.
  """

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Anubis.MCP.Error

  @type read_result ::
          {:reply, Response.t(), Frame.t()}
          | {:error, Error.t(), Frame.t()}

  @doc "Register all resource templates on the frame."
  @spec register_templates(Frame.t()) :: Frame.t()
  def register_templates(frame) do
    frame
    |> Frame.register_resource_template("alexclaw://resources/{id}",
      name: "resources",
      title: "AlexClaw Resources",
      description: "RSS feeds, websites, documents, APIs, and automation configs",
      mime_type: "application/json"
    )
    |> Frame.register_resource_template("alexclaw://knowledge/{id}",
      name: "knowledge",
      title: "Knowledge Base",
      description: "Stored knowledge entries with embeddings (docs, guides, references)",
      mime_type: "application/json"
    )
    |> Frame.register_resource_template("alexclaw://memory/{id}",
      name: "memory",
      title: "Memory Store",
      description: "Ephemeral memories — news items, facts, observations",
      mime_type: "application/json"
    )
    |> Frame.register_resource_template("alexclaw://workflows/{id}",
      name: "workflows",
      title: "Workflow Definitions",
      description: "Workflow definitions with steps, schedules, and resource bindings",
      mime_type: "application/json"
    )
    |> Frame.register_resource_template("alexclaw://runs/{id}",
      name: "runs",
      title: "Workflow Runs",
      description: "Workflow execution history with step results and outcomes",
      mime_type: "application/json"
    )
    |> Frame.register_resource_template("alexclaw://config/{key}",
      name: "config",
      title: "Configuration",
      description: "AlexClaw settings (key-value, by dotted key)",
      mime_type: "application/json"
    )
  end

  @doc "Resolve a resource URI to content. Called by MCP.Server.handle_resource_read/2."
  @spec read(String.t(), Frame.t()) :: read_result()
  def read("alexclaw://resources/" <> id, frame), do: read_resource(id, frame)
  def read("alexclaw://knowledge/" <> id, frame), do: read_knowledge(id, frame)
  def read("alexclaw://memory/" <> id, frame), do: read_memory(id, frame)
  def read("alexclaw://workflows/" <> id, frame), do: read_workflow(id, frame)
  def read("alexclaw://runs/" <> id, frame), do: read_run(id, frame)
  def read("alexclaw://config/" <> key, frame), do: read_config(key, frame)

  def read(uri, frame) do
    {:error, Error.protocol(:invalid_params, %{message: "Unknown resource URI: #{uri}"}), frame}
  end

  # --- Resources (RSS feeds, websites, etc.) ---

  defp read_resource("list", frame) do
    resources = AlexClaw.Resources.list_resources()
    json_reply(Enum.map(resources, &serialize_resource/1), frame)
  end

  defp read_resource(id, frame) do
    case parse_id(id) do
      {:ok, int_id} ->
        case AlexClaw.Resources.get_resource(int_id) do
          {:ok, resource} -> json_reply(serialize_resource(resource), frame)
          {:error, :not_found} -> not_found("resource", id, frame)
        end

      :error ->
        invalid_id(id, frame)
    end
  end

  defp serialize_resource(r) do
    %{
      id: r.id,
      name: r.name,
      type: r.type,
      url: r.url,
      tags: r.tags,
      enabled: r.enabled,
      metadata: r.metadata,
      inserted_at: to_string(r.inserted_at)
    }
  end

  # --- Knowledge ---

  defp read_knowledge("list", frame) do
    entries = AlexClaw.Knowledge.recent(limit: 50)
    json_reply(Enum.map(entries, &serialize_knowledge/1), frame)
  end

  defp read_knowledge("search:" <> query, frame) do
    results = AlexClaw.Knowledge.search(query, limit: 20)
    json_reply(Enum.map(results, &serialize_knowledge/1), frame)
  end

  defp read_knowledge(id, frame) do
    case parse_id(id) do
      {:ok, int_id} ->
        case AlexClaw.Repo.get(AlexClaw.Knowledge.Entry, int_id) do
          nil -> not_found("knowledge entry", id, frame)
          entry -> json_reply(serialize_knowledge(entry), frame)
        end

      :error ->
        invalid_id(id, frame)
    end
  end

  defp serialize_knowledge(e) do
    %{
      id: e.id,
      kind: e.kind,
      content: e.content,
      source: e.source,
      metadata: e.metadata,
      inserted_at: to_string(e.inserted_at)
    }
  end

  # --- Memory ---

  defp read_memory("list", frame) do
    entries = AlexClaw.Memory.recent(limit: 50)
    json_reply(Enum.map(entries, &serialize_memory/1), frame)
  end

  defp read_memory("search:" <> query, frame) do
    results = AlexClaw.Memory.search(query, limit: 20)
    json_reply(Enum.map(results, &serialize_memory/1), frame)
  end

  defp read_memory(id, frame) do
    case parse_id(id) do
      {:ok, int_id} ->
        case AlexClaw.Repo.get(AlexClaw.Memory.Entry, int_id) do
          nil -> not_found("memory entry", id, frame)
          entry -> json_reply(serialize_memory(entry), frame)
        end

      :error ->
        invalid_id(id, frame)
    end
  end

  defp serialize_memory(e) do
    %{
      id: e.id,
      kind: e.kind,
      content: e.content,
      source: e.source,
      metadata: e.metadata,
      inserted_at: to_string(e.inserted_at)
    }
  end

  # --- Workflows ---

  defp read_workflow("list", frame) do
    workflows = AlexClaw.Workflows.list_workflows()
    json_reply(Enum.map(workflows, &serialize_workflow_summary/1), frame)
  end

  defp read_workflow(id, frame) do
    case parse_id(id) do
      {:ok, int_id} ->
        case AlexClaw.Workflows.get_workflow(int_id) do
          {:ok, workflow} -> json_reply(serialize_workflow(workflow), frame)
          {:error, :not_found} -> not_found("workflow", id, frame)
        end

      :error ->
        invalid_id(id, frame)
    end
  end

  defp serialize_workflow_summary(w) do
    %{
      id: w.id,
      name: w.name,
      description: w.description,
      enabled: w.enabled,
      schedule: w.schedule
    }
  end

  defp serialize_workflow(w) do
    %{
      id: w.id,
      name: w.name,
      description: w.description,
      enabled: w.enabled,
      schedule: w.schedule,
      default_provider: w.default_provider,
      node: w.node,
      steps:
        Enum.map(w.steps, fn s ->
          %{
            position: s.position,
            name: s.name,
            skill: s.skill,
            llm_tier: s.llm_tier,
            config: s.config,
            routes: s.routes
          }
        end)
    }
  end

  # --- Workflow Runs ---

  defp read_run("list", frame) do
    import Ecto.Query, only: [from: 2]

    runs =
      from(r in AlexClaw.Workflows.WorkflowRun,
        order_by: [desc: r.started_at],
        limit: 50
      )
      |> AlexClaw.Repo.all()

    json_reply(Enum.map(runs, &serialize_run/1), frame)
  end

  defp read_run(id, frame) do
    case parse_id(id) do
      {:ok, int_id} ->
        case AlexClaw.Workflows.get_run(int_id) do
          {:ok, run} -> json_reply(serialize_run(run), frame)
          {:error, :not_found} -> not_found("workflow run", id, frame)
        end

      :error ->
        invalid_id(id, frame)
    end
  end

  defp serialize_run(r) do
    %{
      id: r.id,
      workflow_id: r.workflow_id,
      status: r.status,
      started_at: to_string(r.started_at),
      completed_at: r.completed_at && to_string(r.completed_at),
      result: r.result,
      error: r.error,
      step_results: r.step_results,
      node: r.node
    }
  end

  # --- Config ---

  defp read_config("list", frame) do
    settings = AlexClaw.Config.list()

    entries =
      Enum.map(settings, fn s ->
        base = %{key: s.key, type: s.type, category: s.category, description: s.description}
        if s.sensitive, do: Map.put(base, :value, "[REDACTED]"), else: Map.put(base, :value, s.value)
      end)

    json_reply(entries, frame)
  end

  defp read_config(key, frame) do
    case AlexClaw.Config.get(key) do
      nil -> not_found("config key", key, frame)
      value -> json_reply(%{key: key, value: value}, frame)
    end
  end

  # --- Helpers ---

  defp json_reply(data, frame) do
    {:reply, Response.resource() |> Response.text(Jason.encode!(data, pretty: true)), frame}
  end

  defp not_found(type, id, frame) do
    {:error, Error.execution("#{type} not found: #{id}"), frame}
  end

  defp invalid_id(id, frame) do
    {:error, Error.protocol(:invalid_params, %{message: "Invalid ID: #{id}"}), frame}
  end

  defp parse_id(id) do
    case Integer.parse(id) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end
end
