defmodule AlexClaw.Auth.AuthContextTest do
  use ExUnit.Case, async: true

  alias AlexClaw.Auth.AuthContext

  describe "build/3" do
    test "builds context for core skill" do
      ctx = AuthContext.build(AlexClaw.Skills.Research, :llm, :all)
      assert ctx.caller == AlexClaw.Skills.Research
      assert ctx.caller_type == :core
      assert ctx.permission == :llm
      assert ctx.chain_depth == 0
      assert %DateTime{} = ctx.timestamp
    end

    test "builds context for dynamic skill" do
      ctx = AuthContext.build(SomeDynamicSkill, :web_read, [:web_read, :llm])
      assert ctx.caller == SomeDynamicSkill
      assert ctx.caller_type == :dynamic
      assert ctx.permission == :web_read
    end

    test "sets chain_depth from process dictionary" do
      Process.put(:auth_chain_depth, 3)
      ctx = AuthContext.build(SomeSkill, :llm, :all)
      assert ctx.chain_depth == 3
      Process.delete(:auth_chain_depth)
    end

    test "enforces required keys" do
      assert_raise ArgumentError, fn ->
        struct!(AuthContext, %{})
      end
    end
  end
end
