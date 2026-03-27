defmodule AlexClaw.Auth.PolicyEngineTest do
  use ExUnit.Case, async: true

  alias AlexClaw.Auth.{AuthContext, PolicyEngine}

  defp build_context(opts \\ []) do
    %AuthContext{
      caller: opts[:caller] || SomeModule,
      caller_type: opts[:caller_type] || :dynamic,
      permission: opts[:permission] || :web_read,
      workflow_run_id: opts[:workflow_run_id],
      chain_depth: opts[:chain_depth] || 0,
      timestamp: DateTime.utc_now()
    }
  end

  describe "core skills" do
    test "always allowed regardless of permission" do
      ctx = build_context(caller_type: :core, permission: :anything)
      assert :allow == PolicyEngine.evaluate(ctx, :all)
    end
  end

  describe "dynamic skills — flat permission check" do
    test "allowed when permission is in the list" do
      ctx = build_context(permission: :web_read)
      assert :allow == PolicyEngine.evaluate(ctx, [:web_read, :llm])
    end

    test "denied when permission is not in the list" do
      ctx = build_context(permission: :memory_write)
      assert {:deny, _reason} = PolicyEngine.evaluate(ctx, [:web_read, :llm])
    end

    test "denied when permissions list is empty" do
      ctx = build_context(permission: :web_read)
      assert {:deny, _reason} = PolicyEngine.evaluate(ctx, [])
    end
  end

  describe "chain depth enforcement" do
    test "allowed at depth 0" do
      ctx = build_context(chain_depth: 0)
      assert :allow == PolicyEngine.evaluate(ctx, [:web_read])
    end

    test "allowed at max depth (3)" do
      ctx = build_context(chain_depth: 3)
      assert :allow == PolicyEngine.evaluate(ctx, [:web_read])
    end

    test "denied when exceeding max depth" do
      ctx = build_context(chain_depth: 4)
      assert {:deny, reason} = PolicyEngine.evaluate(ctx, [:web_read])
      assert reason =~ "chain depth"
    end

    test "denied at very high depth" do
      ctx = build_context(chain_depth: 100)
      assert {:deny, _reason} = PolicyEngine.evaluate(ctx, [:web_read])
    end
  end

  describe "unknown permission state" do
    test "denied when permissions is nil" do
      ctx = build_context()
      assert {:deny, _reason} = PolicyEngine.evaluate(ctx, nil)
    end
  end

  describe "MCP caller type" do
    test "MCP calls are allowed when no mcp_restriction policies exist" do
      ctx = build_mcp_context("skill:system_info")
      assert :allow == PolicyEngine.evaluate(ctx, [])
    end

    test "MCP calls bypass chain depth and token checks" do
      ctx = build_mcp_context("skill:research")
      # MCP path doesn't check chain_depth or token, only policies
      assert :allow == PolicyEngine.evaluate(ctx, [])
    end
  end

  defp build_mcp_context(tool_name) do
    %AuthContext{
      caller: "mcp:#{tool_name}",
      caller_type: :mcp,
      permission: :execute,
      tool_name: tool_name,
      chain_depth: 0,
      timestamp: DateTime.utc_now(),
      token: nil
    }
  end
end
