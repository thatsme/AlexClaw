defmodule AlexClaw.MCP.Server do
  @moduledoc """
  MCP (Model Context Protocol) server: an MCP client reads AlexClaw's data
  and runs its unprotected workflows — nothing more (0.4.0 S5b).

  Uses the Streamable HTTP transport via anubis_mcp. Clients connect to
  the /mcp endpoint and authenticate with a Bearer token. The tools are the
  enabled workflows that need no second factor (`workflow:<name>`); a run is
  performed as `:run_workflow` through `AlexClaw.ControlPlane.perform/3`,
  which refuses a protected one. There are no skill tools: a skill runs
  inside a workflow.

  Resources expose AlexClaw data stores (RSS feeds, knowledge base, memory,
  workflows, runs, config) via URI templates like `alexclaw://knowledge/{id}`.
  """

  use Anubis.Server,
    name: "alexclaw",
    version: AlexClaw.MixProject.project()[:version] || "0.0.0",
    capabilities: [:tools, :resources]

  require Logger

  alias AlexClaw.Auth.{AuthContext, PolicyEngine}
  alias AlexClaw.ControlPlane
  alias AlexClaw.ControlPlane.Context
  alias AlexClaw.MCP.{ResourceProvider, ToolSchema}
  alias Anubis.MCP.Error
  alias Anubis.Server.Frame
  alias Anubis.Server.Response

  @impl true
  @spec init(map(), map()) :: {:ok, map()}
  def init(client_info, frame) do
    Logger.info("[MCP] Client connected: #{inspect(client_info["name"])}")

    frame =
      frame
      |> Frame.assign(:client, to_string(client_info["name"] || "client"))
      |> register_all_tools()
      |> ResourceProvider.register_templates()

    {:ok, frame}
  end

  @impl true
  @spec handle_tool_call(String.t(), map(), map()) :: {:ok, map(), map()} | {:error, map(), map()}
  def handle_tool_call("skill:" <> _skill_name, _arguments, frame) do
    {:reply,
     Response.error(
       Response.tool(),
       "Skills are not tools over MCP: a skill runs inside a workflow."
     ), frame}
  end

  def handle_tool_call("workflow:" <> workflow_name, arguments, frame) do
    with {:find, {:ok, workflow}} <- {:find, find_workflow_by_name(workflow_name)},
         {:policy, :allow} <- {:policy, check_mcp_policy("workflow:#{workflow_name}", :execute)} do
      workflow
      |> run_workflow(arguments, frame)
      |> format_tool_result(frame)
    else
      {:find, {:error, :not_found}} ->
        {:error,
         Error.protocol(:invalid_params, %{message: "Unknown workflow: #{workflow_name}"}), frame}

      {:policy, {:deny, reason}} ->
        {:error, Error.execution(reason), frame}
    end
  end

  def handle_tool_call(name, _arguments, frame) do
    {:error, Error.protocol(:invalid_params, %{message: "Unknown tool: #{name}"}), frame}
  end

  @impl true
  def handle_info(_msg, frame) do
    {:noreply, frame}
  end

  # --- Resources ---

  @impl true
  @spec handle_resource_read(String.t(), map()) :: {:ok, map(), map()} | {:error, map(), map()}
  def handle_resource_read(uri, frame) do
    ResourceProvider.read(uri, frame)
  end

  # --- Policy gate ---

  defp check_mcp_policy(tool_name, permission) do
    tool_name
    |> AuthContext.build_mcp(permission)
    |> PolicyEngine.evaluate([])
  end

  # --- Internal ---

  defp register_all_tools(frame) do
    # Clear existing tools and re-register from current state
    frame = %{frame | tools: %{}}

    Enum.reduce(ToolSchema.all_tools(), frame, fn tool_def, acc ->
      Frame.register_tool(acc, tool_def.name,
        description: tool_def.description,
        input_schema: tool_def.input_schema
      )
    end)
  end

  # The run is performed through the control plane, which refuses a protected
  # or disabled workflow; MCP waits for it and answers with its result.
  defp run_workflow(workflow, arguments, frame) do
    :run_workflow
    |> ControlPlane.perform(
      %{workflow_id: workflow.id, input: arguments["input"], wait: true},
      Context.mcp(frame.assigns[:client] || "client")
    )
    |> ran()
  end

  defp ran({:ok, run}), do: {:ok, %{run_id: run.id, status: run.status, result: run.result}}
  defp ran({:error, reason}), do: {:error, reason}

  defp find_workflow_by_name(name) do
    case Enum.find(AlexClaw.Workflows.list_workflows(), &(&1.name == name)) do
      nil -> {:error, :not_found}
      workflow -> {:ok, workflow}
    end
  end

  defp format_tool_result({:ok, result}, frame) do
    {:reply, build_response(result), frame}
  end

  defp format_tool_result({:error, reason}, frame) do
    message =
      case reason do
        :timeout -> "Tool execution timed out"
        {:crash, r} -> "Tool crashed: #{inspect(r)}"
        r when is_binary(r) -> r
        r -> inspect(r)
      end

    {:reply, Response.error(Response.tool(), message), frame}
  end

  defp build_response(result) when is_binary(result) do
    Response.text(Response.tool(), result)
  end

  defp build_response(result) when is_map(result) or is_list(result) do
    Response.text(Response.tool(), Jason.encode!(result, pretty: true))
  end

  defp build_response(result) do
    Response.text(Response.tool(), inspect(result))
  end
end
