defmodule AlexClaw.MCP.ToolSchemaTest do
  @moduledoc """
  MCP's tool list (0.4.0 S5b): only `workflow:<name>` tools, for enabled,
  unprotected workflows. There are no skill tools any more, so every check
  that looks at a tool first makes sure there is one to look at.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.MCP.ToolSchema

  setup do
    {:ok, wf} =
      AlexClaw.Workflows.create_workflow(%{
        name: "schema-probe-#{System.unique_integer([:positive])}",
        enabled: true
      })

    %{wf: wf}
  end

  describe "all_tools/0" do
    test "returns the workflow tools (no vacuous pass: at least the probe)", %{wf: wf} do
      names = Enum.map(ToolSchema.all_tools(), & &1.name)
      assert "workflow:#{wf.name}" in names
    end

    test "each tool has name, description, and input_schema" do
      tools = ToolSchema.all_tools()
      assert tools != []

      for tool <- tools do
        assert is_binary(tool.name), "tool name should be binary, got: #{inspect(tool.name)}"
        assert is_binary(tool.description), "tool description should be binary for #{tool.name}"
        assert is_map(tool.input_schema), "tool input_schema should be map for #{tool.name}"
      end
    end

    test "every tool is a workflow tool" do
      tools = ToolSchema.all_tools()
      assert tools != []

      for tool <- tools do
        assert String.starts_with?(tool.name, "workflow:"),
               "expected workflow: prefix, got: #{tool.name}"
      end
    end
  end

  describe "workflow_tools/0" do
    test "input_schema uses Peri-compatible types" do
      tools = ToolSchema.workflow_tools()
      assert tools != []

      for tool <- tools, {key, value} <- tool.input_schema do
        assert is_binary(key), "schema key should be string for #{tool.name}"

        assert valid_peri_type?(value),
               "invalid Peri type for #{tool.name}.#{key}: #{inspect(value)}"
      end
    end

    test "returns only enabled workflows" do
      {:ok, disabled} =
        AlexClaw.Workflows.create_workflow(%{
          name: "schema-disabled-#{System.unique_integer([:positive])}",
          enabled: false
        })

      names = Enum.map(ToolSchema.workflow_tools(), & &1.name)
      refute "workflow:#{disabled.name}" in names
    end

    # MCP cannot hold a person's approval, so a workflow that requires 2FA is
    # always refused there; listing it as a tool would offer something that
    # can only fail.
    test "a workflow that requires 2FA is not offered as a tool" do
      suffix = System.unique_integer([:positive])

      {:ok, _} = AlexClaw.Workflows.create_workflow(%{name: "open #{suffix}", enabled: true})

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
      tools = ToolSchema.workflow_tools()
      assert tools != []

      for tool <- tools do
        assert Map.has_key?(tool.input_schema, "input"),
               "workflow tool #{tool.name} should have input field"
      end
    end
  end

  defp valid_peri_type?(type) when is_atom(type), do: true
  defp valid_peri_type?({atom, _}) when is_atom(atom), do: true
  defp valid_peri_type?({atom, _, _}) when is_atom(atom), do: true
  defp valid_peri_type?(map) when is_map(map), do: true
  defp valid_peri_type?(_), do: false
end
