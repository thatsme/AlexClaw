defmodule AlexClaw.MCP.ServerPolicyTest do
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.{Policy, PolicyEngine}
  alias AlexClaw.MCP.Server
  alias AlexClaw.Repo
  alias Anubis.Server.Frame

  # The denies come from the migration, not from this file — asserting against the
  # real seeded rows is the point. PolicyEngine caches in persistent_term, so the
  # cache is reloaded around every test that touches policies.
  setup do
    PolicyEngine.reload_policies()
    on_exit(fn -> PolicyEngine.reload_policies() end)
    :ok
  end

  defp insert_policy(attrs) do
    {:ok, policy} = %Policy{} |> Policy.changeset(attrs) |> Repo.insert()
    PolicyEngine.reload_policies()
    policy
  end

  describe "mcp_restriction is a valid rule type" do
    test "the changeset accepts it" do
      changeset =
        Policy.changeset(%Policy{}, %{
          name: "deny shell",
          rule_type: "mcp_restriction",
          config: %{"tool_pattern" => "skill:shell"}
        })

      assert changeset.valid?
    end

    test "an unknown rule type is still rejected" do
      changeset =
        Policy.changeset(%Policy{}, %{
          name: "nonsense",
          rule_type: "not_a_rule",
          config: %{}
        })

      refute changeset.valid?
    end
  end

  describe "seeded denies" do
    test "every seeded tool is refused over MCP" do
      for tool <- ~w(skill:shell skill:coder skill:db_backup skill:web_automation) do
        assert {:error, error, _frame} = Server.handle_tool_call(tool, %{}, Frame.new())
        assert inspect(error) =~ "MCP restriction"
        assert inspect(error) =~ tool
      end
    end

    test "the seeded policies are present and enabled" do
      seeded =
        Policy
        |> Repo.all()
        |> Enum.filter(&(&1.rule_type == "mcp_restriction" and &1.enabled))
        |> Enum.map(& &1.config["tool_pattern"])

      for tool <- ~w(skill:shell skill:coder skill:db_backup skill:web_automation) do
        assert tool in seeded
      end
    end

    test "disabling the policy lifts the denial" do
      Repo.update_all(
        Ecto.Query.from(p in Policy, where: p.name == "MCP deny skill:shell"),
        set: [enabled: false]
      )

      PolicyEngine.reload_policies()

      # The call now reaches the skill itself, which refuses for its own reason.
      assert {:reply, response, _frame} = Server.handle_tool_call("skill:shell", %{}, Frame.new())
      refute inspect(response) =~ "MCP restriction"
      assert inspect(response) =~ "shell_disabled"
    end

    test "a skill with no deny policy is not stopped by the policy gate" do
      refute match?(
               {:error, %{message: "MCP restriction" <> _}, _},
               Server.handle_tool_call("skill:web_search", %{"query" => ""}, Frame.new())
             )
    end
  end

  describe "match mode" do
    test "exact does not block a different tool sharing the prefix" do
      assert {:error, error, _frame} =
               Server.handle_tool_call("skill:shell_helper", %{}, Frame.new())

      # Rejected as an unknown skill, not by the seeded exact-match policy.
      refute inspect(error) =~ "MCP restriction"
    end

    test "contains blocks any tool containing the pattern" do
      insert_policy(%{
        name: "deny anything search",
        rule_type: "mcp_restriction",
        config: %{"tool_pattern" => "search", "action" => "deny", "match" => "contains"},
        enabled: true
      })

      assert {:error, error, _frame} =
               Server.handle_tool_call("skill:web_search", %{}, Frame.new())

      assert inspect(error) =~ "MCP restriction"
    end

    test "a policy with no match key still behaves as contains" do
      insert_policy(%{
        name: "legacy deny",
        rule_type: "mcp_restriction",
        config: %{"tool_pattern" => "search", "action" => "deny"},
        enabled: true
      })

      assert {:error, error, _frame} =
               Server.handle_tool_call("skill:web_search", %{}, Frame.new())

      assert inspect(error) =~ "MCP restriction"
    end

    test "action other than deny does not block" do
      insert_policy(%{
        name: "audit only",
        rule_type: "mcp_restriction",
        config: %{"tool_pattern" => "skill:web_search", "action" => "audit", "match" => "exact"},
        enabled: true
      })

      refute match?(
               {:error, %{message: "MCP restriction" <> _}, _},
               Server.handle_tool_call("skill:web_search", %{"query" => ""}, Frame.new())
             )
    end
  end
end
