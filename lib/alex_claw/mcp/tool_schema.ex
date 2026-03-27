defmodule AlexClaw.MCP.ToolSchema do
  @moduledoc """
  Maps AlexClaw skills and workflows to MCP tool definitions.

  Converts SkillRegistry entries and Workflow records into the format
  expected by `Anubis.Server.Frame.register_tool/3`: name, description,
  and a JSON Schema `input_schema`.

  Skills are exposed as `skill:<name>`, workflows as `workflow:<name>`.
  """

  alias AlexClaw.Workflows
  alias AlexClaw.Workflows.SkillRegistry

  @type tool_def :: %{
          name: String.t(),
          description: String.t(),
          input_schema: map()
        }

  @doc "Build tool definitions for all registered skills (core + dynamic)."
  @spec skill_tools() :: [tool_def()]
  def skill_tools do
    SkillRegistry.list_all_with_type()
    |> Enum.map(&skill_to_tool/1)
  end

  @doc "Build tool definitions for all enabled workflows."
  @spec workflow_tools() :: [tool_def()]
  def workflow_tools do
    Workflows.list_workflows()
    |> Enum.filter(& &1.enabled)
    |> Enum.map(&workflow_to_tool/1)
  end

  @doc "Build all tool definitions (skills + workflows)."
  @spec all_tools() :: [tool_def()]
  def all_tools, do: skill_tools() ++ workflow_tools()

  # --- Skill conversion ---

  defp skill_to_tool({name, module, type, _permissions, routes}) do
    description = skill_description(module, name, type)

    %{
      name: "skill:#{name}",
      description: description,
      input_schema: skill_input_schema(name, routes)
    }
  end

  defp skill_description(module, name, type) do
    Code.ensure_loaded(module)

    base =
      if function_exported?(module, :description, 0) do
        module.description()
      else
        "#{name} skill"
      end

    type_tag = if type == :dynamic, do: " [dynamic]", else: ""
    base <> type_tag
  end

  defp skill_input_schema(name, routes) do
    config_fields = skill_config_schema(name)

    base = %{
      "input" => {:string, description: "Input data passed to the skill (string, or JSON-encoded)"},
      "config" => {:map, :any, description: "Skill-specific configuration keys"}
    }

    schema = Map.merge(base, config_fields)
    maybe_add_routes_to_description(schema, routes)
  end

  defp maybe_add_routes_to_description(schema, routes) when is_list(routes) and routes != [] do
    route_names = Enum.map_join(routes, ", ", &to_string/1)
    current = get_in(schema, ["input"]) |> elem(1) |> Keyword.get(:description, "")
    new_desc = "#{current} Possible output branches: #{route_names}."

    put_in(schema, ["input"], {:string, description: new_desc})
  end

  defp maybe_add_routes_to_description(schema, _routes), do: schema

  # Known config schemas for core skills (Peri format).
  # Dynamic skills use the generic config object.
  defp skill_config_schema("web_search") do
    %{
      "query" => {:string, description: "Search query string"},
      "max_results" => {:integer, description: "Maximum results to return"}
    }
  end

  defp skill_config_schema("web_browse") do
    %{
      "url" => {:string, description: "URL to fetch"},
      "extract" => {:string, description: "Content extraction mode"}
    }
  end

  defp skill_config_schema("rss_collector") do
    %{
      "max_items" => {:integer, description: "Maximum RSS items to collect"}
    }
  end

  defp skill_config_schema("research") do
    %{
      "topic" => {:string, description: "Research topic"},
      "depth" => {:string, description: "Research depth: light, medium, deep"}
    }
  end

  defp skill_config_schema("llm_transform") do
    %{
      "system_prompt" => {:string, description: "System prompt for the LLM"},
      "model" => {:string, description: "Model override"}
    }
  end

  defp skill_config_schema("api_request") do
    %{
      "url" => {:string, description: "Request URL"},
      "method" => {:string, description: "HTTP method (GET, POST, etc.)"},
      "headers" => {:map, :string, description: "Request headers"},
      "body" => {:string, description: "Request body"}
    }
  end

  defp skill_config_schema("shell") do
    %{
      "command" => {:string, description: "Shell command to execute"}
    }
  end

  defp skill_config_schema("telegram_notify") do
    %{
      "message" => {:string, description: "Message text to send"}
    }
  end

  defp skill_config_schema("discord_notify") do
    %{
      "message" => {:string, description: "Message text to send"}
    }
  end

  defp skill_config_schema("send_to_workflow") do
    %{
      "target_node" => {:string, description: "Target BEAM node name"},
      "target_workflow" => {:string, description: "Target workflow name"},
      "timeout" => {:integer, description: "RPC timeout in milliseconds"}
    }
  end

  defp skill_config_schema(_name), do: %{}

  # --- Workflow conversion ---

  defp workflow_to_tool(workflow) do
    description = workflow.description || "Run the #{workflow.name} workflow"

    %{
      name: "workflow:#{workflow.name}",
      description: description,
      input_schema: %{
        "input" => {:string, description: "Optional initial input for the workflow. Passed to the first step."}
      }
    }
  end
end
