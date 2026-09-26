defmodule AlexClaw.MCP.OperateNotAuthorTest do
  @moduledoc """
  An MCP client reads, and runs unprotected workflows — nothing more
  (reports/S5_ONE_DOOR.md §4.2; reports/S5_INVENTORY.md §8; 0.4.0 S5b).

  The inventory found MCP could change what a workflow does: it offered a
  tool for every skill, and minted core skills a token with every
  permission. Now:
  - no `skill:` tools at all — `ToolSchema.skill_tools/0` is empty, and a
    call to one is refused;
  - `workflow:` tools only for workflows that are enabled and NOT protected;
    a call to a protected one is refused, and starts no run;
  - no tool writes anything (no create, update, delete, load, add, set).
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  import Ecto.Query

  alias AlexClaw.MCP.{Server, ToolSchema}
  alias AlexClaw.Workflows
  alias Anubis.Server.Frame

  defp tool_names, do: Enum.map(ToolSchema.all_tools(), &(&1[:name] || &1["name"] || &1.name))

  defp runs_of(wf_id) do
    Repo.aggregate(
      from(r in AlexClaw.Workflows.WorkflowRun, where: r.workflow_id == ^wf_id),
      :count
    )
  end

  test "there are no skill tools" do
    assert ToolSchema.skill_tools() == []
    refute Enum.any?(tool_names(), &String.starts_with?(&1, "skill"))
  end

  test "no tool writes anything" do
    writers =
      Enum.filter(tool_names(), &(&1 =~ ~r/create|update|delete|load|add_|set_|write|remove/i))

    assert writers == [], "MCP offers tools that write: #{inspect(writers)}"
  end

  test "a call to a skill tool is refused" do
    assert {:reply, response, _frame} =
             Server.handle_tool_call("skill:web_search", %{}, Frame.new())

    assert response.isError == true or
             inspect(response) =~ ~r/not (found|allowed|available)|unknown/i
  end

  describe "workflow tools" do
    setup do
      {:ok, open} =
        Workflows.create_workflow(%{
          name: "mcp-open-#{System.unique_integer([:positive])}",
          enabled: true
        })

      # Protection is read from metadata["requires_2fa"] (workflow.ex:31,45);
      # a top-level attribute is not cast.
      {:ok, protected} =
        Workflows.create_workflow(%{
          name: "mcp-protected-#{System.unique_integer([:positive])}",
          enabled: true,
          metadata: %{"requires_2fa" => true}
        })

      %{open: open, protected: protected}
    end

    test "exist for an unprotected workflow, not for a protected one", %{
      open: open,
      protected: protected
    } do
      names = Enum.join(tool_names(), " ")

      assert names =~ open.name,
             "the unprotected workflow has no tool — the check would prove nothing"

      refute names =~ protected.name
    end

    test "calling a protected workflow by name is refused and starts no run", %{
      protected: protected
    } do
      before = runs_of(protected.id)

      assert {:reply, response, _frame} =
               Server.handle_tool_call("workflow:#{protected.name}", %{}, Frame.new())

      assert response.isError == true or
               inspect(response) =~ ~r/not (found|allowed)|protected|approval/i

      assert runs_of(protected.id) == before
    end
  end
end
