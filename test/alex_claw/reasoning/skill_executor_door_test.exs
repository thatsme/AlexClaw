defmodule AlexClaw.Reasoning.SkillExecutorDoorTest do
  @moduledoc """
  The reasoning loop runs a skill through the control plane's door, like any
  other caller (S8 M6; THREAT_MODEL P2, P6).

  The model chooses the skill; the whitelist narrows the choice; the door
  decides. So a privileged skill is refused even when the whitelist names it,
  and every run leaves a `run_skill` row in the audit log.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.AuditEntry
  alias AlexClaw.Reasoning.SkillExecutor

  defp run_skill_rows do
    Repo.all(from(e in AuditEntry, where: like(e.reason, "run_skill%")))
  end

  test "a privileged skill is refused, even when whitelisted" do
    assert {:error, :privileged_skill} =
             SkillExecutor.execute("shell", %{input: "ls"}, ["shell"])
  end

  test "a run is audited as run_skill" do
    SkillExecutor.execute("receive_from_workflow", %{input: "x"}, ["receive_from_workflow"])

    assert run_skill_rows() != []
  end
end
