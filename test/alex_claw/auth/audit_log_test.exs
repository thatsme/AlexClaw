defmodule AlexClaw.Auth.AuditLogTest do
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.{AuditLog, AuthContext}

  defp build_context(opts \\ %{}) do
    defaults = %AuthContext{
      caller: "test_skill",
      caller_type: :skill,
      permission: :llm,
      workflow_run_id: nil,
      chain_depth: 0,
      timestamp: DateTime.utc_now(),
      token: nil
    }

    struct(defaults, opts)
  end

  describe "log_deny/2" do
    test "returns :ok" do
      ctx = build_context()
      assert :ok = AuditLog.log_deny(ctx, "test denial reason")
    end
  end

  describe "log_allow/1" do
    test "returns :ok" do
      ctx = build_context()
      assert :ok = AuditLog.log_allow(ctx)
    end
  end

  describe "recent/1" do
    test "returns a list" do
      assert is_list(AuditLog.recent())
    end

    test "accepts limit option" do
      assert is_list(AuditLog.recent(limit: 5))
    end

    test "accepts decision filter" do
      assert is_list(AuditLog.recent(decision: "deny"))
    end
  end

  describe "prune/0" do
    test "returns tuple without crashing" do
      {count, _} = AuditLog.prune()
      assert is_integer(count)
    end
  end
end
