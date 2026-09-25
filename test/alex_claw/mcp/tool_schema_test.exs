defmodule AlexClaw.MCP.ToolSchemaTest do
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.MCP.ToolSchema

  describe "all_tools/0" do
    test "returns a list of tool definitions" do
      tools = ToolSchema.all_tools()
      assert is_list(tools)
      refute Enum.empty?(tools)
    end

    test "each tool has name, description, and input_schema" do
      for tool <- ToolSchema.all_tools() do
        assert is_binary(tool.name), "tool name should be binary, got: #{inspect(tool.name)}"
        assert is_binary(tool.description), "tool description should be binary for #{tool.name}"
        assert is_map(tool.input_schema), "tool input_schema should be map for #{tool.name}"
      end
    end

    test "skill tools are prefixed with skill:" do
      skills = ToolSchema.skill_tools()

      for tool <- skills do
        assert String.starts_with?(tool.name, "skill:"),
               "expected skill: prefix, got: #{tool.name}"
      end
    end

    test "workflow tools are prefixed with workflow:" do
      workflows = ToolSchema.workflow_tools()

      for tool <- workflows do
        assert String.starts_with?(tool.name, "workflow:"),
               "expected workflow: prefix, got: #{tool.name}"
      end
    end
  end

  describe "skill_tools/0" do
    test "input_schema uses Peri-compatible types" do
      tools = ToolSchema.skill_tools()

      for tool <- tools do
        schema = tool.input_schema

        for {key, value} <- schema do
          assert is_binary(key), "schema key should be string for #{tool.name}"

          assert valid_peri_type?(value),
                 "invalid Peri type for #{tool.name}.#{key}: #{inspect(value)}"
        end
      end
    end
  end

  describe "workflow_tools/0" do
    test "returns only enabled workflows" do
      workflows = ToolSchema.workflow_tools()

      for tool <- workflows do
        name = String.replace_leading(tool.name, "workflow:", "")
        wf = Enum.find(AlexClaw.Workflows.list_workflows(), &(&1.name == name))
        assert wf == nil or wf.enabled, "disabled workflow should not be in tool list: #{name}"
      end
    end

    # MCP cannot hold a person's approval, so a workflow that requires 2FA is
    # always refused there (requires_two_factor_test.exs); listing it as a tool
    # would offer something that can only fail.
    test "a workflow that requires 2FA is not offered as a tool" do
      suffix = System.unique_integer([:positive])

      {:ok, _} =
        AlexClaw.Workflows.create_workflow(%{
          name: "open #{suffix}",
          enabled: true
        })

      {:ok, _} =
        AlexClaw.Workflows.create_workflow(%{
          name: "protected #{suffix}",
          enabled: true,
          metadata: %{"requires_2fa" => true}
        })

      names = Enum.map(ToolSchema.workflow_tools(), & &1.name)

      assert "workflow:open #{suffix}" in names
      refute "workflow:protected #{suffix}" in names
    end

    test "workflow tools have input field in schema" do
      for tool <- ToolSchema.workflow_tools() do
        assert Map.has_key?(tool.input_schema, "input"),
               "workflow tool #{tool.name} should have input field"
      end
    end
  end

  # Validates that a value is a valid Peri schema type
  defp valid_peri_type?(type) when is_atom(type), do: true
  defp valid_peri_type?({atom, _}) when is_atom(atom), do: true
  defp valid_peri_type?({atom, _, _}) when is_atom(atom), do: true
  defp valid_peri_type?(map) when is_map(map), do: true
  defp valid_peri_type?(_), do: false
end
