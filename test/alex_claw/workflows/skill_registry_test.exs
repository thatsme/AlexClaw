defmodule AlexClaw.Workflows.SkillRegistryTest do
  use ExUnit.Case, async: true

  alias AlexClaw.Workflows.SkillRegistry

  describe "resolve/1" do
    test "resolves all registered skills" do
      for name <- SkillRegistry.list_skills() do
        assert {:ok, module} = SkillRegistry.resolve(name)
        assert is_atom(module)
      end
    end

    test "resolves known skills to correct modules" do
      assert {:ok, AlexClaw.Skills.RSSCollector} = SkillRegistry.resolve("rss_collector")
      assert {:ok, AlexClaw.Skills.WebSearch} = SkillRegistry.resolve("web_search")
      assert {:ok, AlexClaw.Skills.WebBrowse} = SkillRegistry.resolve("web_browse")
      assert {:ok, AlexClaw.Skills.TelegramNotify} = SkillRegistry.resolve("telegram_notify")
      assert {:ok, AlexClaw.Skills.ApiRequest} = SkillRegistry.resolve("api_request")
    end

    test "returns error for unknown skill" do
      assert {:error, :unknown_skill} = SkillRegistry.resolve("nonexistent")
      assert {:error, :unknown_skill} = SkillRegistry.resolve("")
    end
  end

  describe "list_skills/0" do
    test "returns sorted list of skill names" do
      skills = SkillRegistry.list_skills()
      assert is_list(skills)
      assert skills == Enum.sort(skills)
      assert "rss_collector" in skills
      assert "telegram_notify" in skills
      assert "api_request" in skills
    end
  end
end
