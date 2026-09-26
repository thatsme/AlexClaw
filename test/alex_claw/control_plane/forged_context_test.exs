defmodule AlexClaw.ControlPlane.ForgedContextTest do
  @moduledoc """
  A control-plane context is what its constructor built, and nothing else
  (S8 M5; THREAT_MODEL P2).

  Each constructor seals the context it builds; `perform/3` checks the seal.
  A context changed afterwards — its proof, entry point, node or identity
  rewritten by a struct update — is refused as unverified before anything
  else is looked at, as is one from `new/3`, which states its proof outright
  and exists for `authorize/2` alone.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.ControlPlane
  alias AlexClaw.ControlPlane.Context

  for {what, forged} <- [
        {"a gateway context claiming a code", quote(do: %{Context.gateway("42") | proof: :code})},
        {"a gateway context claiming to be the system",
         quote(do: %{Context.gateway("42") | entry_point: :system})},
        {"a system context claiming to be a cluster node",
         quote(do: %{Context.system("x") | entry_point: :cluster, node: "evil@host"})},
        {"an admin context with another identity",
         quote(do: %{Context.admin_ui(nil) | identity: "admin:someone-else"})},
        {"a context from new/3", quote(do: Context.new(:system, "system:x", :elevation))}
      ] do
    test "refuses #{what}" do
      assert {:error, :unverified_context} =
               ControlPlane.perform(:upgrade_secrets, %{}, unquote(forged))
    end
  end

  test "a context as its constructor built it is not refused as unverified" do
    refute ControlPlane.perform(:clear_run_history, %{workflow_id: -1}, Context.gateway("42")) ==
             {:error, :unverified_context}
  end
end
