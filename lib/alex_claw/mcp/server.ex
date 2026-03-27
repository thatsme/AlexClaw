defmodule AlexClaw.MCP.Server do
  @moduledoc """
  MCP (Model Context Protocol) server exposing AlexClaw skills and workflows as tools.

  Uses the Streamable HTTP transport via anubis_mcp. Clients connect to
  the /mcp endpoint, authenticate with a Bearer token, and can discover
  and invoke AlexClaw skills through the standard MCP protocol.

  Tool discovery is dynamic: when skills are loaded/unloaded/reloaded,
  connected clients receive a `notifications/tools/list_changed` notification
  and can re-fetch the tool list.
  """

  use Anubis.Server,
    name: "alexclaw",
    version: AlexClaw.MixProject.project()[:version] || "0.0.0",
    capabilities: [:tools]

  require Logger

  alias AlexClaw.Auth.{AuthContext, PolicyEngine}
  alias AlexClaw.MCP.ToolSchema

  @skills_topic "skills:registry"

  @impl true
  def init(client_info, frame) do
    Logger.info("[MCP] Client connected: #{inspect(client_info["name"])}")

    # Subscribe this session to skill registry changes
    Phoenix.PubSub.subscribe(AlexClaw.PubSub, @skills_topic)

    frame = register_all_tools(frame)

    {:ok, frame}
  end

  @impl true
  def handle_tool_call("skill:" <> skill_name, arguments, frame) do
    with {:resolve, {:ok, module}} <- {:resolve, AlexClaw.Workflows.SkillRegistry.resolve(skill_name)},
         {:policy, :allow} <- {:policy, check_mcp_policy("skill:#{skill_name}", :execute)} do
      args = build_skill_args(arguments)
      result = execute_skill(module, skill_name, args)
      format_tool_result(result, frame)
    else
      {:resolve, {:error, :unknown_skill}} ->
        {:error, %{"code" => -32602, "message" => "Unknown skill: #{skill_name}"}, frame}

      {:policy, {:deny, reason}} ->
        {:error, %{"code" => -32603, "message" => reason}, frame}
    end
  end

  def handle_tool_call("workflow:" <> workflow_name, arguments, frame) do
    with {:find, {:ok, workflow}} <- {:find, find_workflow_by_name(workflow_name)},
         {:policy, :allow} <- {:policy, check_mcp_policy("workflow:#{workflow_name}", :execute)} do
      result = execute_workflow(workflow, arguments)
      format_tool_result(result, frame)
    else
      {:find, {:error, :not_found}} ->
        {:error, %{"code" => -32602, "message" => "Unknown workflow: #{workflow_name}"}, frame}

      {:policy, {:deny, reason}} ->
        {:error, %{"code" => -32603, "message" => reason}, frame}
    end
  end

  def handle_tool_call(name, _arguments, frame) do
    {:error, %{"code" => -32602, "message" => "Unknown tool: #{name}"}, frame}
  end

  # PubSub events from SkillRegistry — re-register all tools and notify client
  @impl true
  def handle_info({:skill_registered, name}, frame) do
    Logger.info("[MCP] Skill registered: #{name}, refreshing tool list")
    frame = register_all_tools(frame)
    send_tools_list_changed()
    {:noreply, frame}
  end

  def handle_info({:skill_unregistered, name}, frame) do
    Logger.info("[MCP] Skill unregistered: #{name}, refreshing tool list")
    frame = register_all_tools(frame)
    send_tools_list_changed()
    {:noreply, frame}
  end

  def handle_info(_msg, frame) do
    {:noreply, frame}
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

    ToolSchema.all_tools()
    |> Enum.reduce(frame, fn tool_def, acc ->
      Anubis.Server.Frame.register_tool(acc, tool_def.name,
        description: tool_def.description,
        input_schema: tool_def.input_schema
      )
    end)
  end

  defp build_skill_args(arguments) do
    %{
      input: arguments["input"],
      config: arguments["config"] || %{},
      resources: [],
      workflow_run_id: nil,
      llm_provider: nil,
      llm_tier: arguments["llm_tier"] || "medium",
      prompt_template: nil
    }
  end

  defp execute_skill(module, _skill_name, args) do
    type = AlexClaw.Workflows.SkillRegistry.get_type(module)

    task =
      Task.Supervisor.async_nolink(AlexClaw.TaskSupervisor, fn ->
        permissions =
          if type == :dynamic do
            AlexClaw.Workflows.SkillRegistry.get_permissions(module)
          else
            AlexClaw.Skills.SkillAPI.known_permissions()
          end

        token = AlexClaw.Auth.CapabilityToken.mint(permissions)
        Process.put(:auth_token, token)

        module.run(args)
      end)

    timeout = Application.get_env(:alex_claw, :mcp_tool_timeout_ms, 30_000)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
      {:exit, reason} -> {:error, {:crash, reason}}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp execute_workflow(workflow, arguments) do
    input = arguments["input"]

    if input do
      AlexClaw.Workflows.Executor.run_with_input(workflow.id, input)
    else
      AlexClaw.Workflows.Executor.run(workflow.id)
    end
    |> case do
      {:ok, run} ->
        {:ok, %{
          run_id: run.id,
          status: run.status,
          result: run.result
        }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_workflow_by_name(name) do
    case AlexClaw.Workflows.list_workflows()
         |> Enum.find(&(&1.name == name)) do
      nil -> {:error, :not_found}
      workflow -> {:ok, workflow}
    end
  end

  defp format_tool_result({:ok, result, _branch}, frame) do
    {:reply, format_content(result), frame}
  end

  defp format_tool_result({:ok, result}, frame) do
    {:reply, format_content(result), frame}
  end

  defp format_tool_result({:error, reason}, frame) do
    text =
      case reason do
        :timeout -> "Tool execution timed out"
        {:crash, r} -> "Tool crashed: #{inspect(r)}"
        r when is_binary(r) -> r
        r -> inspect(r)
      end

    {:reply, [%{"type" => "text", "text" => text, "isError" => true}], frame}
  end

  defp format_content(result) when is_binary(result) do
    [%{"type" => "text", "text" => result}]
  end

  defp format_content(result) when is_map(result) or is_list(result) do
    [%{"type" => "text", "text" => Jason.encode!(result, pretty: true)}]
  end

  defp format_content(result) do
    [%{"type" => "text", "text" => inspect(result)}]
  end
end
