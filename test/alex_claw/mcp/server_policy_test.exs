defmodule AlexClaw.MCP.ServerPolicyTest do
  @moduledoc """
  MCP restriction policies (mcp_restriction), since 0.4.0 (S5b).

  MCP offers only `workflow:<name>` tools now — enabled, unprotected
  workflows — so restriction policies match those. The seeded denies for
  `skill:shell`, `skill:coder`, `skill:db_backup` and `skill:web_automation`
  guarded tools that no longer exist; a rule that protects nothing makes a
  reader believe something is protected, so they are removed.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.{Policy, PolicyEngine}
  alias AlexClaw.MCP.Server
  alias AlexClaw.{Repo, Workflows}
  alias Anubis.Server.Frame

  # PolicyEngine caches in persistent_term, so the cache is reloaded around
  # every test that touches policies.
  setup do
    # A workflow tool that is not denied starts a real run in its own process.
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    PolicyEngine.reload_policies()
    on_exit(fn -> PolicyEngine.reload_policies() end)

    suffix = System.unique_integer([:positive])

    {:ok, wf} =
      Workflows.create_workflow(%{name: "policy-search-#{suffix}", enabled: true})

    %{tool: "workflow:#{wf.name}", wf: wf}
  end

  defp insert_policy(attrs) do
    {:ok, policy} = %Policy{} |> Policy.changeset(attrs) |> Repo.insert()
    PolicyEngine.reload_policies()
    policy
  end

  defp restricted?(tool) do
    inspect(Server.handle_tool_call(tool, %{"input" => ""}, Frame.new())) =~ "MCP restriction"
  end

  describe "mcp_restriction is a valid rule type" do
    test "the changeset accepts it" do
      changeset =
        Policy.changeset(%Policy{}, %{
          name: "deny a workflow",
          rule_type: "mcp_restriction",
          config: %{"tool_pattern" => "workflow:nightly"}
        })

      assert changeset.valid?
    end

    test "an unknown rule type is still rejected" do
      changeset =
        Policy.changeset(%Policy{}, %{name: "nonsense", rule_type: "not_a_rule", config: %{}})

      refute changeset.valid?
    end
  end

  describe "the old seeded skill denies" do
    test "are gone: no policy names a skill: tool" do
      skill_rules =
        Policy
        |> Repo.all()
        |> Enum.filter(&(&1.rule_type == "mcp_restriction"))
        |> Enum.map(& &1.config["tool_pattern"])
        |> Enum.filter(&(is_binary(&1) and String.starts_with?(&1, "skill:")))

      assert skill_rules == [],
             "dead rules for tools that no longer exist: #{inspect(skill_rules)}"
    end
  end

  describe "matching a workflow tool" do
    test "with no policy, the tool is not stopped by the policy gate", %{tool: tool} do
      refute restricted?(tool)
    end

    test "exact blocks the named tool and not one sharing its prefix", %{tool: tool} do
      insert_policy(%{
        name: "deny exact",
        rule_type: "mcp_restriction",
        config: %{"tool_pattern" => tool <> "-other", "action" => "deny", "match" => "exact"},
        enabled: true
      })

      refute restricted?(tool)
    end

    test "contains blocks any tool containing the pattern", %{tool: tool} do
      insert_policy(%{
        name: "deny anything search",
        rule_type: "mcp_restriction",
        config: %{"tool_pattern" => "search", "action" => "deny", "match" => "contains"},
        enabled: true
      })

      assert restricted?(tool)
    end

    test "a policy with no match key still behaves as contains", %{tool: tool} do
      insert_policy(%{
        name: "legacy deny",
        rule_type: "mcp_restriction",
        config: %{"tool_pattern" => "search", "action" => "deny"},
        enabled: true
      })

      assert restricted?(tool)
    end

    test "action other than deny does not block", %{tool: tool} do
      insert_policy(%{
        name: "audit only",
        rule_type: "mcp_restriction",
        config: %{"tool_pattern" => tool, "action" => "audit", "match" => "exact"},
        enabled: true
      })

      refute restricted?(tool)
    end

    test "disabling the policy lifts the denial", %{tool: tool} do
      policy =
        insert_policy(%{
          name: "deny then lift",
          rule_type: "mcp_restriction",
          config: %{"tool_pattern" => tool, "action" => "deny", "match" => "exact"},
          enabled: true
        })

      assert restricted?(tool)

      Repo.update_all(Ecto.Query.from(p in Policy, where: p.id == ^policy.id),
        set: [enabled: false]
      )

      PolicyEngine.reload_policies()

      refute restricted?(tool)
    end
  end
end
