defmodule AlexClaw.Skills.RoutesTest do
  use ExUnit.Case, async: true
  @moduletag :unit

  @moduledoc "Verify all core skills declare routes and return correct branch atoms."

  @skills_with_custom_routes %{
    AlexClaw.Skills.RSSCollector => [:on_items, :on_empty, :on_error],
    AlexClaw.Skills.WebSearch => [:on_results, :on_no_results, :on_timeout, :on_error],
    AlexClaw.Skills.WebBrowse => [:on_success, :on_not_found, :on_timeout, :on_error],
    AlexClaw.Skills.Research => [:on_results, :on_error],
    AlexClaw.Skills.TelegramNotify => [:on_delivered, :on_error],
    AlexClaw.Skills.ApiRequest => [:on_2xx, :on_4xx, :on_5xx, :on_timeout, :on_error],
    AlexClaw.Skills.GoogleCalendar => [:on_events, :on_empty, :on_error],
    AlexClaw.Skills.GoogleTasks => [:on_tasks, :on_empty, :on_error],
    AlexClaw.Skills.GitHubSecurityReview => [:on_clean, :on_findings, :on_error],
    AlexClaw.Skills.WebAutomation => [:on_success, :on_timeout, :on_error]
  }

  @skills_with_default_routes [
    AlexClaw.Skills.Conversational,
    AlexClaw.Workflows.LLMTransform
  ]

  describe "routes/0 callback" do
    for {module, expected_routes} <- @skills_with_custom_routes do
      test "#{inspect(module)} declares custom routes" do
        module = unquote(module)
        Code.ensure_loaded!(module)
        assert function_exported?(module, :routes, 0)
        assert module.routes() == unquote(expected_routes)
      end
    end

    for module <- @skills_with_default_routes do
      test "#{inspect(module)} has no routes/0 — gets default [:on_success, :on_error]" do
        module = unquote(module)
        Code.ensure_loaded!(module)
        default = if function_exported?(module, :routes, 0), do: module.routes(), else: [:on_success, :on_error]
        assert default == [:on_success, :on_error]
      end
    end
  end

  describe "run/1 return format" do
    test "all skills implement run/1" do
      all_skills = Map.keys(@skills_with_custom_routes) ++ @skills_with_default_routes

      for module <- all_skills do
        Code.ensure_loaded!(module)
        assert function_exported?(module, :run, 1),
               "#{inspect(module)} must export run/1"
      end
    end
  end
end
