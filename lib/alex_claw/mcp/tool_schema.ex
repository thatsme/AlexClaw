defmodule AlexClaw.MCP.ToolSchema do
  @moduledoc """
  Maps AlexClaw workflows to MCP tool definitions.

  Converts Workflow records into the format expected by
  `Anubis.Server.Frame.register_tool/3`: name, description, and a JSON
  Schema `input_schema`. Workflows are exposed as `workflow:<name>`; there
  are no skill tools.
  """

  alias AlexClaw.Workflows
  alias AlexClaw.Workflows.Workflow

  @type tool_def :: %{
          name: String.t(),
          description: String.t(),
          input_schema: map()
        }

  @doc """
  The skill tools: none. An MCP client runs workflows; a skill runs inside
  one (0.4.0 S5b).
  """
  @spec skill_tools() :: [tool_def()]
  def skill_tools, do: []

  @doc """
  Build tool definitions for all enabled workflows, except those that require
  2FA: MCP cannot carry a person's approval, so such a workflow would always
  be refused.
  """
  @spec workflow_tools() :: [tool_def()]
  def workflow_tools do
    Workflows.list_workflows()
    |> Enum.filter(&(&1.enabled and not Workflow.protected?(&1)))
    |> Enum.map(&workflow_to_tool/1)
  end

  @doc "Build all tool definitions (the workflows)."
  @spec all_tools() :: [tool_def()]
  def all_tools, do: skill_tools() ++ workflow_tools()

  # --- Workflow conversion ---

  defp workflow_to_tool(workflow) do
    description = workflow.description || "Run the #{workflow.name} workflow"

    %{
      name: "workflow:#{workflow.name}",
      description: description,
      input_schema: %{
        "input" =>
          {:string,
           description: "Optional initial input for the workflow. Passed to the first step."}
      }
    }
  end
end
