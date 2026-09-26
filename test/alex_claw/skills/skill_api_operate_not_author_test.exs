defmodule AlexClaw.Skills.SkillAPIOperateNotAuthorTest do
  @moduledoc """
  A skill uses AlexClaw; it never authors it (reports/S5_INVENTORY.md §8;
  THREAT_MODEL.md P2, P6; 0.4.0 S5b).

  SkillAPI let a skill, on a permission alone and with no audit row, create
  workflows, add steps (to protected workflows too), write skill files
  straight into the live directory, load/unload/reload skills (recording a
  "totp" approval without any code), and start workflow runs. A skill is
  untrusted code — dynamic skills are written by users or by a model — so
  these functions are removed, not gated: no permission can bring them back.

  What stays: reading resources (redacted), knowledge and memory, LLM calls,
  HTTP through the guard, sending messages, running other skills
  (`run_skill`, which the catalogue allows a skill), reading its own
  outcomes, and reading a workflow run's result (`get_workflow_result`, under
  its own read-only permission `workflow_read`).

  `read_skill` goes with the rest: reading other skills' source is an
  authoring aid, not something a skill needs to operate.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  alias AlexClaw.Skills.SkillAPI

  @removed ~w(create_workflow add_workflow_step write_skill read_skill load_skill unload_skill
              reload_skill run_workflow)a

  @kept ~w(get_resource list_resources llm_complete http_get send_message run_skill
           memory_search get_workflow_result)a

  defp exported_names do
    SkillAPI.__info__(:functions) |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
  end

  test "the authoring functions are gone, at every arity" do
    still_there = Enum.filter(@removed, &(&1 in exported_names()))
    assert still_there == [], "SkillAPI still exports: #{inspect(still_there)}"
  end

  test "what a skill legitimately uses is still there (no vacuous pass)" do
    for kept <- @kept do
      assert kept in exported_names(), "#{kept} disappeared too"
    end
  end

  # By name: the three permissions that granted authoring — skill_write
  # (write/read skill files), skill_manage (load/unload/reload), and
  # workflow_manage (create, add steps, run) — are gone. Reading a run's
  # result has its own read-only permission.
  test "no permission grants authoring; reading a run's result has its own" do
    permissions = Enum.map(SkillAPI.known_permissions(), &to_string/1)

    for gone <- ~w(skill_write skill_manage workflow_manage) do
      refute gone in permissions, "#{gone} is still a permission"
    end

    assert "workflow_read" in permissions
  end
end
