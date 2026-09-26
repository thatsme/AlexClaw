defmodule AlexClaw.Reasoning.WhitelistDefaultTest do
  @moduledoc """
  The reasoning loop's default skill whitelist holds no skill that writes to
  the user's accounts (S9 fix review, M6 ruling). The loop's plan comes from
  a model reading fetched pages and feeds: text brought in that way must not
  be able to steer it into writing to Google Tasks. An admin may still add
  such a skill to the list.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Config.{Seeder, Setting}

  test "a fresh install's whitelist does not include google_tasks" do
    Repo.delete_all(from(s in Setting, where: s.key == "reasoning.skill_whitelist"))
    :ok = Seeder.seed()

    %Setting{value: value} = Repo.get_by!(Setting, key: "reasoning.skill_whitelist")
    whitelist = Jason.decode!(value)

    assert "web_search" in whitelist, "the default list was not seeded"
    refute "google_tasks" in whitelist
  end
end
